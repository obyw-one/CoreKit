import CoreKit
import CoreKitTestSupport
import Foundation
import Testing

// MARK: - Settings file owner

private struct Tree {
    static let config = VirtualNode("config")
    private init() {}
}

/// The configuration as an owned file in the tree: a `.raw` entry, `cat`-able.
private struct AppConfigFile: VirtualPathOwning {
    static let placement = VirtualPlacement(node: Tree.config, name: "app-config")
    let query: AppConfigQuery

    func location() throws(VirtualPathError) -> VirtualPath {
        VirtualPath(try PathSegment("\(query.storageKey).json"))
    }
}

// MARK: - ConfigEndpointBackingKind

enum ConfigEndpointBackingKind: String, CaseIterable, Sendable {
    case settingsFile
    case inMemoryCache
    case asyncObjectStore
    case plainRepository
    case scripted
}

// MARK: - ConfigEndpointBackingTests

@Suite("ConfigEndpoint backings — the same AppConfig from each, no consumer changes (W5)")
struct ConfigEndpointBackingTests {

    private static let seeded = AppConfigQuery(appId: "demo", environment: "prod")
    private static let unknown = AppConfigQuery(appId: "ghost", environment: "prod")

    private func harness(_ kind: ConfigEndpointBackingKind) async throws -> (ConfigEndpointHarness, tearDown: @Sendable () -> Void) {
        let expected = ConfigEndpointConformance.sampleConfig(for: Self.seeded)
        var tearDown: @Sendable () -> Void = {}
        let endpoint: any ConfigEndpoint

        switch kind {
        case .settingsFile:
            let scratch = TestScratch.forPackage()
            let root = try scratch.makeScratchDir(scope: "config-endpoint")
            tearDown = { scratch.sweep(root) }
            let paths = try PathLayer(root: root, registry: VirtualPathRegistry([AppConfigFile.self]))
            let file = try paths.url(for: AppConfigFile(query: Self.seeded))
            let repository = CacheRepository<AppConfig>(
                "settings", invalidateTime: .never, baseDirectory: file.deletingLastPathComponent(),
                envelope: .raw, naming: .bareId(ext: "json"), codec: .humanReadable)
            try repository.save(Self.seeded.storageKey, data: expected)
            endpoint = RepositoryConfigEndpoint(repository: repository)

        case .inMemoryCache:
            let repository = AsyncCacheRepository<AppConfig>("config", invalidateTime: .never, backing: InMemoryCacheBacking())
            try await repository.save(Self.seeded.storageKey, data: expected)
            endpoint = RepositoryConfigEndpoint(repository: repository)

        case .asyncObjectStore:
            let repository = AsyncCacheRepository<AppConfig>(
                "config", invalidateTime: .never,
                backing: ObjectStoreCacheBacking(client: InMemoryObjectStoreClient(), bucket: "evidence", node: "mac-a"))
            try await repository.save(Self.seeded.storageKey, data: expected)
            endpoint = RepositoryConfigEndpoint(repository: repository)

        case .plainRepository:
            let repository = InMemoryRepository<String, AppConfig>()
            try await repository.save(Self.seeded.storageKey, data: expected)
            endpoint = RepositoryConfigEndpoint(repository: repository)

        case .scripted:
            endpoint = ScriptedEndpoint(seeded: Self.seeded, config: expected)
        }
        return (
            ConfigEndpointHarness(
                label: kind.rawValue, endpoint: endpoint, query: Self.seeded, expected: expected, unknownQuery: Self.unknown),
            tearDown
        )
    }

    @Test("the endpoint contract holds over each backing",
          arguments: ConfigEndpointBackingKind.allCases, ConfigEndpointConformance.Check.allCases)
    func contract(kind: ConfigEndpointBackingKind, check: ConfigEndpointConformance.Check) async throws {
        let (harness, tearDown) = try await harness(kind)
        defer { tearDown() }
        let violations = await ConfigEndpointConformance.run(check, on: harness)
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("the settings file is the config's JSON, readable as it is, at the owner's resolved location")
    func settingsFileIsReadableJSON() async throws {
        let scratch = TestScratch.forPackage()
        let root = try scratch.makeScratchDir(scope: "config-settings-file")
        defer { scratch.sweep(root) }
        let paths = try PathLayer(root: root, registry: VirtualPathRegistry([AppConfigFile.self]))
        let file = try paths.url(for: AppConfigFile(query: Self.seeded))
        let repository = CacheRepository<AppConfig>(
            "settings", invalidateTime: .never, baseDirectory: file.deletingLastPathComponent(),
            envelope: .raw, naming: .bareId(ext: "json"), codec: .humanReadable)
        let expected = ConfigEndpointConformance.sampleConfig(for: Self.seeded)
        try repository.save(Self.seeded.storageKey, data: expected)

        #expect(file.lastPathComponent == "demo-prod.json")
        #expect(PathContainment.isContained(file, in: root))
        let onDisk = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: file))
        #expect(onDisk == expected)
    }

    @Test("a service over any backing reports the same configuration to its consumer")
    func consumerUnchangedBySwap() async throws {
        var blocks: [AppBlock?] = []
        var versions: [Bool] = []
        for kind in ConfigEndpointBackingKind.allCases {
            let (harness, tearDown) = try await harness(kind)
            defer { tearDown() }
            let service = AppConfigService(
                query: Self.seeded, endpoint: harness.endpoint,
                cache: AsyncCacheRepository<AppConfig>("svc", invalidateTime: .never, backing: InMemoryCacheBacking()))
            #expect(await service.bootstrap() == .fetched, "\(kind)")
            blocks.append(await service.block)
            versions.append(await service.currentConfig?.requiresUpdate(installedVersion: "1.0.0") ?? false)
        }
        #expect(Set(blocks.map { String(describing: $0) }).count == 1, "backings disagreed about the block: \(blocks)")
        #expect(Set(versions).count == 1)
    }

    @Test("a source with nothing for the app is reported as not found, not as a generic failure")
    func notFoundIsTyped() async throws {
        let endpoint = RepositoryConfigEndpoint(repository: InMemoryRepository<String, AppConfig>())
        await #expect(throws: ConfigEndpointError.notFound(Self.unknown)) { _ = try await endpoint.fetchConfig(Self.unknown) }
        #expect(ConfigEndpointError.notFound(Self.unknown).description.contains("ghost"))
    }

    @Test("a repository failure that is not a miss passes through unchanged")
    func otherFailuresPassThrough() async {
        let endpoint = RepositoryConfigEndpoint(repository: BrokenRepository())
        await #expect(throws: BrokenRepository.Boom()) { _ = try await endpoint.fetchConfig(Self.seeded) }
    }

    @Test("every check in the endpoint suite is exercised")
    func populationIsComplete() {
        #expect(ConfigEndpointConformance.Check.allCases.count == 4)
        #expect(ConfigEndpointBackingKind.allCases.count == 5)
    }
}

// MARK: - BrokenRepository

/// A repository whose every read fails with something that is not a miss.
private struct BrokenRepository: RepositoryProtocol {
    struct Boom: Error, Equatable {}

    func get(_ id: String) async throws -> AppConfig { throw Boom() }
    func list() async throws -> [AppConfig] { [] }
    func save(_ id: String, data: AppConfig) async throws {}
    func delete(_ id: String) async throws {}
}

// MARK: - ScriptedEndpoint

/// A source that answers for exactly one query.
private struct ScriptedEndpoint: ConfigEndpoint {
    let seeded: AppConfigQuery
    let config: AppConfig

    func fetchConfig(_ query: AppConfigQuery) async throws -> AppConfig {
        guard query == seeded else { throw ConfigEndpointError.notFound(query) }
        return config
    }
}
