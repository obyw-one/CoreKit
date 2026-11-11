import CoreKit
import CoreKitTestSupport
import Foundation
import Testing

// MARK: - Fixtures

private enum AppFlag: String, FeatureFlagKey {
    case featureX = "feature_x"
    case maxItems = "max_items"
    case debugTab = "debug_tab"

    func localDefault(for distribution: Distribution) -> FlagValue {
        switch self {
        case .featureX: .bool(false)
        case .maxItems: .int(10)
        case .debugTab: .bool(distribution == .debug)
        }
    }

    var isRemoteControllable: Bool { self != .debugTab }
}

private struct Unreachable: Error, Equatable {}

/// A repository that remembers nothing and refuses every write.
private struct Refusing: RepositoryProtocol {
    func get(_ id: String) async throws -> AppConfig { throw RepositoryError.notFound(id: id) }
    func list() async throws -> [AppConfig] { [] }
    func save(_ id: String, data: AppConfig) async throws { throw Unreachable() }
    func delete(_ id: String) async throws { throw Unreachable() }
}

/// An endpoint that parks every request until released, and counts them.
private actor GatedEndpoint: ConfigEndpoint {
    private(set) var calls = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let answer: AppConfig

    init(answer: AppConfig) {
        self.answer = answer
    }

    func fetchConfig(_ query: AppConfigQuery) async throws -> AppConfig {
        calls += 1
        await withCheckedContinuation { waiting.append($0) }
        return answer
    }

    func releaseAll() {
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

/// A cache whose FIRST read parks until released (and then answers with a
/// stale configuration); every later read is a miss.
private actor ParkedFirstReadCache: RepositoryProtocol {
    private var parked: CheckedContinuation<Void, Never>?
    private var firstReadStarted = false
    private let stale: AppConfig

    init(stale: AppConfig) {
        self.stale = stale
    }

    var isParked: Bool { parked != nil }

    func get(_ id: String) async throws -> AppConfig {
        guard !firstReadStarted else { throw RepositoryError.notFound(id: id) }
        firstReadStarted = true
        await withCheckedContinuation { parked = $0 }
        return stale
    }

    func release() {
        parked?.resume()
        parked = nil
    }

    func list() async throws -> [AppConfig] { [] }
    func save(_ id: String, data: AppConfig) async throws {}
    func delete(_ id: String) async throws {}
}

private let query = AppConfigQuery(appId: "demo", environment: "prod")

private func config(
    appId: String = "demo", killSwitch: Bool = false, maintenance: Bool = false, flags: [String: FlagValue] = [:]
) -> AppConfig {
    AppConfig(
        id: "rec", appId: appId, minVersion: "1.0.0", latestVersion: "2.0.0", killSwitch: killSwitch,
        maintenanceMode: maintenance, maintenanceMessage: nil, featureFlags: RemoteFeatureFlags(flags), configData: nil)
}

/// A repository the service remembers in — in memory, so no test touches a disk.
private func makeCache() -> AsyncCacheRepository<AppConfig> {
    AsyncCacheRepository<AppConfig>("app-config", invalidateTime: .never, backing: InMemoryCacheBacking())
}

private struct SUT {
    let service: AppConfigService
    let endpoint: StubConfigEndpoint
    let cache: AsyncCacheRepository<AppConfig>
}

private func makeSUT(
    endpoint: Result<AppConfig, any Error>,
    cache: AsyncCacheRepository<AppConfig> = makeCache()
) -> SUT {
    let stub = StubConfigEndpoint(endpoint)
    return SUT(service: AppConfigService(query: query, endpoint: stub, cache: cache), endpoint: stub, cache: cache)
}

// MARK: - AppConfigServiceTests

@Suite("AppConfigService — fetch once, cache, run on the cache or on nothing (BR-RP-13)")
struct AppConfigServiceTests {

    @Test("before any bootstrap there is no configuration: nothing is invented")
    func startsEmpty() async {
        let sut = makeSUT(endpoint: .success(config()))
        #expect(await sut.service.currentConfig == nil)
        #expect(await sut.service.block == nil)
        #expect(await !sut.service.isBlocked)
    }

    @Test("a successful bootstrap holds the configuration and remembers it")
    func fetchedIsCached() async throws {
        let sut = makeSUT(endpoint: .success(config(flags: ["feature_x": .bool(true)])))
        #expect(await sut.service.bootstrap() == .fetched)
        #expect(await sut.service.currentConfig?.featureFlags.values["feature_x"] == .bool(true))
        let remembered = try await sut.cache.get(query.storageKey)
        #expect(remembered == (await sut.service.currentConfig))
        #expect(await sut.endpoint.requests == [query])
    }

    @Test("when the endpoint is down the cached configuration is used, and the result says so")
    func downEndpointUsesCache() async throws {
        let cache = makeCache()
        try await cache.save(query.storageKey, data: config(maintenance: true))
        let sut = makeSUT(endpoint: .failure(Unreachable()), cache: cache)
        #expect(await sut.service.bootstrap() == .usingCache)
        #expect(await sut.service.isBlocked)
        #expect(await sut.service.block == .maintenance(message: nil))
    }

    @Test("with the endpoint down and no cache there is no configuration")
    func nothingAnywhere() async {
        let sut = makeSUT(endpoint: .failure(Unreachable()))
        #expect(await sut.service.bootstrap() == .unavailable)
        #expect(await sut.service.currentConfig == nil)
        #expect(await !sut.service.isBlocked)
    }

    @Test("restore loads the last known configuration without asking the endpoint")
    func restoreDoesNotAsk() async throws {
        let cache = makeCache()
        try await cache.save(query.storageKey, data: config(killSwitch: true))
        let sut = makeSUT(endpoint: .success(config()), cache: cache)
        await sut.service.restore()
        #expect(await sut.service.block == .killSwitch(message: nil))
        #expect(await sut.endpoint.requests.isEmpty)
    }

    @Test("a fresh answer replaces the cached one, in memory and in the cache")
    func freshReplacesCached() async throws {
        let cache = makeCache()
        try await cache.save(query.storageKey, data: config(killSwitch: true))
        let sut = makeSUT(endpoint: .success(config(killSwitch: false)), cache: cache)
        #expect(await sut.service.bootstrap() == .fetched)
        #expect(await !sut.service.isBlocked)
        #expect(try await cache.get(query.storageKey).killSwitch == false)
    }

    @Test("a configuration for another app is refused from the endpoint")
    func otherAppFromEndpoint() async {
        let sut = makeSUT(endpoint: .success(config(appId: "someone-else", killSwitch: true)))
        #expect(await sut.service.bootstrap() == .unavailable)
        #expect(await !sut.service.isBlocked, "a kill switch for another app was applied")
    }

    @Test("a cached configuration for another app is ignored")
    func otherAppFromCache() async throws {
        let cache = makeCache()
        try await cache.save(query.storageKey, data: config(appId: "someone-else", killSwitch: true))
        let sut = makeSUT(endpoint: .failure(Unreachable()), cache: cache)
        #expect(await sut.service.bootstrap() == .unavailable)
        #expect(await !sut.service.isBlocked)
    }

    @Test("a cache that cannot be written does not lose the fresh configuration")
    func unwritableCacheKeepsFresh() async {
        let service = AppConfigService(query: query, endpoint: StubConfigEndpoint(.success(config())), cache: Refusing())
        #expect(await service.bootstrap() == .fetched)
        #expect(await service.currentConfig != nil)
    }

    @Test("reads from many tasks while a bootstrap runs are safe")
    func concurrentReads() async {
        let sut = makeSUT(endpoint: .success(config()))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await sut.service.bootstrap() }
            for _ in 0..<50 {
                group.addTask { _ = await sut.service.currentConfig
                    _ = await sut.service.block
                }
            }
        }
        #expect(await sut.service.currentConfig != nil)
    }

    // MARK: Reentrancy

    @Test("concurrent bootstraps join the one fetch in flight instead of racing a second")
    func bootstrapsCoalesce() async {
        let endpoint = GatedEndpoint(answer: config())
        let service = AppConfigService(query: query, endpoint: endpoint, cache: makeCache())
        async let first = service.bootstrap()
        async let second = service.bootstrap()
        // Wait until the first fetch is parked at the endpoint, then give a second
        // fetch (the regression) ample chances to reach it. A correct service never does.
        while await endpoint.calls == 0 { await Task.yield() }
        for _ in 0..<2_000 { await Task.yield() }
        #expect(await endpoint.calls == 1, "a second bootstrap raced its own fetch")
        await endpoint.releaseAll()
        #expect(await first == .fetched)
        #expect(await second == .fetched)
        #expect(await endpoint.calls == 1)
    }

    @Test("a restore that was suspended on the cache does not overwrite what a bootstrap installed meanwhile")
    func restoreDoesNotClobberFresher() async {
        let cache = ParkedFirstReadCache(stale: config(killSwitch: true))
        let service = AppConfigService(
            query: query, endpoint: StubConfigEndpoint(.success(config(killSwitch: false))), cache: cache)
        let restoring = Task { await service.restore() }
        while await !cache.isParked { await Task.yield() }
        #expect(await service.bootstrap() == .fetched)
        await cache.release()
        await restoring.value
        #expect(await service.currentConfig?.killSwitch == false, "the stale cached configuration replaced the fresh one")
        #expect(await !service.isBlocked)
    }

    // MARK: Flags from the configuration

    @Test("server flag overrides reach the resolver after a bootstrap, with no refresh step")
    func configBackedFlags() async {
        let sut = makeSUT(endpoint: .success(config(flags: ["feature_x": .bool(true), "debug_tab": .bool(true)])))
        let flags = ConfigBackedFeatureFlags<AppFlag>(distribution: .release, service: sut.service)
        #expect(await flags.resolve("feature_x") == FlagResolution(name: "feature_x", value: .bool(false), source: .localDefault))
        await sut.service.bootstrap()
        let resolved = await flags.resolve("feature_x")
        #expect(resolved.value == .bool(true))
        #expect(resolved.source == .remote)
        #expect(await flags.resolve("debug_tab").value == .bool(false), "the pinned flag stayed local")
        #expect(await flags.resolve("unknown") == .unavailable("unknown"))
    }

    // MARK: DI and the mock

    @Test("the DI slot hands components the one service")
    func diSlot() async throws {
        let container = Container(name: "config")
        DIAssemblyAppConfig(service: MockAppConfigService(config: config(maintenance: true)))
            .assemble(container: container, environment: .mock)
        let service = try container.resolve((any AppConfigServiceProtocol).self)
        #expect(await service.isBlocked)
    }

    @Test("the mock holds what the test sets and reports it")
    func mock() async {
        let mock = MockAppConfigService()
        #expect(await mock.bootstrap() == .unavailable)
        await mock.setConfig(config(killSwitch: true))
        #expect(await mock.bootstrap() == .fetched)
        #expect(await mock.block == .killSwitch(message: nil))
        await mock.setConfig(nil)
        #expect(await mock.currentConfig == nil)
    }
}
