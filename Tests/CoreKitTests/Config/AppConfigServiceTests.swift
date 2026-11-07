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

private let query = AppConfigQuery(appId: "demo", environment: "prod")

private func config(
    appId: String = "demo", killSwitch: Bool = false, maintenance: Bool = false, flags: [String: FlagValue] = [:]
) -> AppConfig {
    AppConfig(
        id: "rec", appId: appId, minVersion: "1.0.0", latestVersion: "2.0.0", killSwitch: killSwitch,
        maintenanceMode: maintenance, maintenanceMessage: nil, featureFlags: RemoteFeatureFlags(flags), configData: nil)
}

/// A repository the service remembers in — in memory, so no test touches a disk.
private func makeCache() -> CacheRepository<AppConfig> {
    CacheRepository<AppConfig>("app-config", invalidateTime: .never, backing: InMemoryCacheBacking())
}

private struct SUT {
    let service: AppConfigService
    let endpoint: StubConfigEndpoint
    let cache: CacheRepository<AppConfig>
}

private func makeSUT(
    endpoint: Result<AppConfig, any Error>,
    cache: CacheRepository<AppConfig> = makeCache()
) -> SUT {
    let stub = StubConfigEndpoint(endpoint)
    return SUT(service: AppConfigService(query: query, endpoint: stub, cache: cache), endpoint: stub, cache: cache)
}

// MARK: - AppConfigServiceTests

@Suite("AppConfigService — fetch once, cache, run on the cache or on nothing (BR-RP-13)")
struct AppConfigServiceTests {

    @Test("before any bootstrap there is no configuration: nothing is invented")
    func startsEmpty() {
        let sut = makeSUT(endpoint: .success(config()))
        #expect(sut.service.currentConfig == nil)
        #expect(sut.service.block == nil)
        #expect(!sut.service.isBlocked)
    }

    @Test("a successful bootstrap holds the configuration and remembers it")
    func fetchedIsCached() async throws {
        let sut = makeSUT(endpoint: .success(config(flags: ["feature_x": .bool(true)])))
        #expect(await sut.service.bootstrap() == .fetched)
        #expect(sut.service.currentConfig?.featureFlags.values["feature_x"] == .bool(true))
        #expect(try sut.cache.get(query.storageKey) == sut.service.currentConfig)
        #expect(await sut.endpoint.requests == [query])
    }

    @Test("when the endpoint is down the cached configuration is used, and the result says so")
    func downEndpointUsesCache() async throws {
        let cache = makeCache()
        try cache.save(query.storageKey, data: config(maintenance: true))
        let sut = makeSUT(endpoint: .failure(Unreachable()), cache: cache)
        #expect(await sut.service.bootstrap() == .usingCache)
        #expect(sut.service.isBlocked)
        #expect(sut.service.block == .maintenance(message: nil))
    }

    @Test("with the endpoint down and no cache there is no configuration")
    func nothingAnywhere() async {
        let sut = makeSUT(endpoint: .failure(Unreachable()))
        #expect(await sut.service.bootstrap() == .unavailable)
        #expect(sut.service.currentConfig == nil)
        #expect(!sut.service.isBlocked)
    }

    @Test("restore loads the last known configuration without asking the endpoint")
    func restoreDoesNotAsk() async throws {
        let cache = makeCache()
        try cache.save(query.storageKey, data: config(killSwitch: true))
        let sut = makeSUT(endpoint: .success(config()), cache: cache)
        await sut.service.restore()
        #expect(sut.service.block == .killSwitch(message: nil))
        #expect(await sut.endpoint.requests.isEmpty)
    }

    @Test("a fresh answer replaces the cached one, in memory and in the cache")
    func freshReplacesCached() async throws {
        let cache = makeCache()
        try cache.save(query.storageKey, data: config(killSwitch: true))
        let sut = makeSUT(endpoint: .success(config(killSwitch: false)), cache: cache)
        #expect(await sut.service.bootstrap() == .fetched)
        #expect(!sut.service.isBlocked)
        #expect(try cache.get(query.storageKey).killSwitch == false)
    }

    @Test("a configuration for another app is refused from the endpoint")
    func otherAppFromEndpoint() async {
        let sut = makeSUT(endpoint: .success(config(appId: "someone-else", killSwitch: true)))
        #expect(await sut.service.bootstrap() == .unavailable)
        #expect(!sut.service.isBlocked, "a kill switch for another app was applied")
    }

    @Test("a cached configuration for another app is ignored")
    func otherAppFromCache() async throws {
        let cache = makeCache()
        try cache.save(query.storageKey, data: config(appId: "someone-else", killSwitch: true))
        let sut = makeSUT(endpoint: .failure(Unreachable()), cache: cache)
        #expect(await sut.service.bootstrap() == .unavailable)
        #expect(!sut.service.isBlocked)
    }

    @Test("a cache that cannot be written does not lose the fresh configuration")
    func unwritableCacheKeepsFresh() async {
        let service = AppConfigService(query: query, endpoint: StubConfigEndpoint(.success(config())), cache: Refusing())
        #expect(await service.bootstrap() == .fetched)
        #expect(service.currentConfig != nil)
    }

    @Test("reads from many tasks while a bootstrap runs are safe")
    func concurrentReads() async {
        let sut = makeSUT(endpoint: .success(config()))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await sut.service.bootstrap() }
            for _ in 0..<50 {
                group.addTask { _ = sut.service.currentConfig; _ = sut.service.block }
            }
        }
        #expect(sut.service.currentConfig != nil)
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
        #expect(service.isBlocked)
    }

    @Test("the mock holds what the test sets and reports it")
    func mock() async {
        let mock = MockAppConfigService()
        #expect(await mock.bootstrap() == .unavailable)
        mock.setConfig(config(killSwitch: true))
        #expect(await mock.bootstrap() == .fetched)
        #expect(mock.block == .killSwitch(message: nil))
        mock.setConfig(nil)
        #expect(mock.currentConfig == nil)
    }
}
