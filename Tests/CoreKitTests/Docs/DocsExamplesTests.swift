import CoreKit
import CoreKitTestSupport
import Foundation
import Testing

// The code blocks of docs/*.md, compiled. If an API in a doc changes, this file stops building.

private struct Evidence: Codable, Sendable, Equatable { let wave: Int }

private func record(_ evidence: Evidence, in cache: some RepositoryProtocol<String, Evidence>) async throws {
    try await cache.save("wave-\(evidence.wave)", data: evidence)
}

private func evidenceCache(
    endpoint: URL, region: String, accessKey: String, secretKey: String, node: NodeID
) throws -> AsyncCacheRepository<Evidence> {
    let client = try S3ObjectStoreClient(
        endpoint: endpoint,
        region: region,
        credentials: S3Credentials(accessKey: accessKey, secretKey: secretKey),
        transport: URLSessionS3Transport(),
        clock: { Date() })
    let backing = ObjectStoreCacheBacking(client: client, bucket: "evidence", node: node)
    return AsyncCacheRepository<Evidence>("evidence", invalidateTime: .never, envelope: .raw, backing: backing)
}

private struct Tree {
    static let flows = VirtualNode("flows")
    static let state = VirtualNode("state")
    private init() {}
}

private struct PlansLedger: VirtualPathOwning {
    static let placement = VirtualPlacement(node: Tree.state, name: "plans.json")
}

private struct FlowMetadata: VirtualPathOwning {
    static let placement = VirtualPlacement(node: Tree.flows, name: "metadata.json")
    let flowID: String

    func location() throws(VirtualPathError) -> VirtualPath {
        VirtualPath(try PathSegment(flowID), try PathSegment("\(flowID)-metadata.json"))
    }
}

private enum AgencyEnvKey: String, EnvKeyProviding {
    case dataRoot = "AGENCY_DATA_ROOT"
    case verbose = "AGENCY_VERBOSE"
    case port = "AGENCY_PORT"

    var defaultValue: String? {
        switch self {
        case .verbose: "false"
        case .dataRoot, .port: nil
        }
    }
}

private enum AppFlag: String, FeatureFlagKey {
    case featureX = "feature_x"
    case debugTab = "debug_tab"

    func localDefault(for distribution: Distribution) -> FlagValue {
        .bool(distribution == .debug)
    }

    var isRemoteControllable: Bool { self != .debugTab }
}

@Suite("docs/*.md examples compile and do what the page says")
struct DocsExamplesTests {

    @Test("cache.md: the same code over a folder and over memory")
    func swapping() async throws {
        let scratch = TestScratch.forPackage()
        let directory = try scratch.makeScratchDir(scope: "docs-cache")
        defer { try? scratch.removeScratchDir(directory) }
        let local = CacheRepository<Evidence>("evidence", invalidateTime: .never, baseDirectory: directory)
        let memory = AsyncCacheRepository<Evidence>("evidence", invalidateTime: .never, backing: InMemoryCacheBacking())
        try await record(Evidence(wave: 1), in: local)
        try await record(Evidence(wave: 1), in: memory)
        #expect(try local.get("wave-1") == Evidence(wave: 1))
        #expect(try await memory.get("wave-1") == Evidence(wave: 1))
    }

    @Test("cache.md: the S3 cache builds from injected values")
    func s3Builds() throws {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "store.example.test"
        components.port = 3900
        let endpoint = try #require(components.url)
        let cache = try evidenceCache(endpoint: endpoint, region: "test-region", accessKey: "key", secretKey: "secret", node: "mac-a")
        #expect(cache.name == "evidence")
    }

    @Test("paths.md: owners, registry, layer")
    func paths() throws {
        let scratch = TestScratch.forPackage()
        let root = try scratch.makeScratchDir(scope: "docs-paths")
        defer { try? scratch.removeScratchDir(root) }
        let registry = try VirtualPathRegistry([PlansLedger.self, FlowMetadata.self])
        let layer = try PathLayer(root: root, registry: registry)
        #expect(try layer.url(for: PlansLedger()).lastPathComponent == "plans.json")
        #expect(try layer.url(for: FlowMetadata(flowID: "7f3a")).lastPathComponent == "7f3a-metadata.json")
        let address = try layer.address(for: FlowMetadata(flowID: "7f3a"), bucket: "evidence", nodeID: "mac-a")
        #expect(address.node == "mac-a")

        let run = try TestRunRoot(base: root, branch: "feature/x", correlationID: "run-01", target: "MyTests")
        let container = Container(name: "test")
        try DIAssemblyResourcePathsMock(run: run, owners: [PlansLedger.self]).assemble(container: container, environment: .mock)
        #expect(throws: Never.self) { try container.resolve((any PathResolving).self) }
    }

    @Test("environment-and-flags.md: env keys")
    func envKeys() throws {
        let env = TypedEnvironment(["AGENCY_DATA_ROOT": "data", "AGENCY_PORT": "8080"])
        #expect(try env.require(AgencyEnvKey.dataRoot) == "data")
        #expect(try env.require(AgencyEnvKey.port, as: Int.self) == 8080)
        #expect(env.resolve(AgencyEnvKey.verbose) == "false")
        #expect(throws: EnvKeyError.missing(name: "AGENCY_DATA_ROOT")) { try TypedEnvironment.empty.require(AgencyEnvKey.dataRoot) }
    }

    @Test("environment-and-flags.md: flags")
    func flags() {
        let flags = FeatureFlags<AppFlag>(distribution: .release)
            .merged(with: RemoteFeatureFlags(["feature_x": .bool(true), "debug_tab": .bool(true)]))
        #expect(flags.isEnabled(.featureX))
        #expect(!flags.isEnabled(.debugTab))
    }

    @Test("config.md: bootstrap over a settings file")
    func config() async throws {
        let scratch = TestScratch.forPackage()
        let directory = try scratch.makeScratchDir(scope: "docs-config")
        defer { try? scratch.removeScratchDir(directory) }
        let query = AppConfigQuery(appId: "demo", environment: "prod")
        let settings = CacheRepository<AppConfig>(
            "settings", invalidateTime: .never, baseDirectory: directory, envelope: .raw, naming: .bareId(ext: "json"))
        try settings.save(query.storageKey, data: ConfigEndpointConformance.sampleConfig(for: query))
        let service = AppConfigService(
            query: query,
            endpoint: RepositoryConfigEndpoint(repository: settings),
            cache: AsyncCacheRepository<AppConfig>("app-config", invalidateTime: .never, backing: InMemoryCacheBacking()))
        #expect(await service.bootstrap() == .fetched)
        #expect(await service.block?.message == "Back shortly — é")
    }
}
