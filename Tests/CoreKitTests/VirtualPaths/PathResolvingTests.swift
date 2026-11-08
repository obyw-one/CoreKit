import CoreKit
import CoreKitTestSupport
import Foundation
import Testing

// MARK: - Fixtures

private enum Tree: String, VirtualNodeNaming {
    case flows, state, queue
    case aiRouting = "ai-routing"
    var parent: Tree? { self == .aiRouting ? .state : nil }
}

/// A single resource: the static placement is the whole declaration.
private struct PlansLedger: VirtualPathOwning {
    static let placement = VirtualPlacement(node: Tree.state, name: "plans.json")
}

/// An id-dependent resource: the id is a folder AND part of the file name (BR-RP-02, T-03).
private struct FlowMetadata: VirtualPathOwning {
    static let placement = VirtualPlacement(node: Tree.flows, name: "metadata.json")
    let flowID: String

    func location() throws(VirtualPathError) -> VirtualPath {
        VirtualPath(try PathSegment(flowID), try PathSegment("\(flowID)-metadata.json"))
    }
}

/// A family of files: one typed enum with placement and location, never N accessors.
private enum QueueFile: String, CaseIterable, VirtualPathOwning {
    case fastPending = "fast-pending.jsonl"
    case retryPending = "retry-pending.jsonl"

    static let placement = VirtualPlacement(node: Tree.queue, name: "queue-file")

    func location() throws(VirtualPathError) -> VirtualPath {
        VirtualPath(try PathSegment(rawValue))
    }
}

/// Claims the same placement as `PlansLedger` under a different type.
private struct ImpostorLedger: VirtualPathOwning {
    static let placement = PlansLedger.placement
}

/// Never added to any tree.
private struct Stranger: VirtualPathOwning {
    static let placement = VirtualPlacement(node: Tree.state, name: "stranger.json")
}

private let allOwners: [any VirtualPathOwning.Type] = [PlansLedger.self, FlowMetadata.self, QueueFile.self]

private struct Sandbox {
    let scratch = TestScratch.forPackage()
    let dir: URL

    init(_ scope: String) throws {
        dir = try scratch.makeScratchDir(scope: scope)
    }

    func sweep() { scratch.sweep(dir) }

    func child(_ name: String) -> URL { dir.appending(path: name, directoryHint: .isDirectory) }
}

private func webURL() throws -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "example.com"
    return try #require(components.url)
}

private func layer(_ root: URL, nodeRoots: [Tree: URL] = [:]) throws -> PathLayer {
    try PathLayer(root: root, nodeRoots: nodeRoots, registry: VirtualPathRegistry(allOwners))
}

// MARK: - PathResolvingTests

@Suite("PathResolving — one protocol over an injected root (BR-RP-01..04)")
struct PathResolvingTests {

    private static let slash = PathSeparator.posix.rawValue

    // MARK: T-01 — prod and test differ only by the injected root

    @Test("T-01: prod and test resolve the SAME owner to locations that differ only by the root")
    func prodAndTestDifferOnlyByRoot() throws {
        let box = try Sandbox("resolving-t01")
        defer { box.sweep() }

        let prodRoot = box.child("prod")
        let run = try TestRunRoot(
            base: box.child("home"), branch: ["feat", "x"].joined(separator: Self.slash),
            correlationID: "corr-01", target: "CoreKitTests")

        let prod = Container(name: "prod")
        let test = Container(name: "test")
        DIAssemblyResourcePaths(layer: try layer(prodRoot)).assemble(container: prod, environment: .production)
        try DIAssemblyResourcePathsMock(run: run, owners: allOwners).assemble(container: test, environment: .mock)

        let prodPaths = try prod.resolve((any PathResolving).self)
        let testPaths = try test.resolve((any PathResolving).self)

        let owner = FlowMetadata(flowID: "7f3a")
        let prodURL = try prodPaths.url(for: owner)
        let testURL = try testPaths.url(for: owner)

        #expect(prodPaths.root == prodRoot.standardizedFileURL)
        #expect(testPaths.root == run.url.standardizedFileURL)
        #expect(prodURL != testURL)
        // The virtual path is root-free, so it is identical; the URL is the root plus it.
        #expect(try prodPaths.virtualPath(for: owner) == testPaths.virtualPath(for: owner))
        #expect(prodURL.path.hasPrefix(prodPaths.root.path))
        #expect(testURL.path.hasPrefix(testPaths.root.path))
        #expect(String(prodURL.path.dropFirst(prodPaths.root.path.count))
            == String(testURL.path.dropFirst(testPaths.root.path.count)))
    }

    @Test("T-01: every owner kind resolves identically under both roots")
    func everyOwnerKind() throws {
        let box = try Sandbox("resolving-t01-all")
        defer { box.sweep() }
        let one = try layer(box.child("one"))
        let two = try layer(box.child("two"))
        for file in QueueFile.allCases {
            #expect(try one.virtualPath(for: file) == two.virtualPath(for: file))
        }
        #expect(try one.virtualPath(for: PlansLedger()) == two.virtualPath(for: PlansLedger()))
    }

    // MARK: T-02 — containment is a check

    @Test("T-02: an id that climbs is refused when the owner resolves", arguments: PathResolvingTests.hostileIds)
    func climbingIdRefused(_ id: String) throws {
        let box = try Sandbox("resolving-t02-ids")
        defer { box.sweep() }
        let paths = try layer(box.child("root"))
        #expect(throws: VirtualPathError.self) { try paths.url(for: FlowMetadata(flowID: id)) }
        #expect(throws: VirtualPathError.self) { try paths.virtualPath(for: FlowMetadata(flowID: id)) }
    }

    private static let hostileIds: [String] = {
        let up = PathVocabulary.parentComponent
        return [
            up,
            [up, up, up, up, "flows"].joined(separator: slash),
            [up, "x"].joined(separator: PathSeparator.windows.rawValue),
            ["ok", "x"].joined(separator: slash),
        ]
    }()

    @Test("T-02: a symlink inside a node that points out of it is refused")
    func symlinkEscapeRefused() throws {
        let box = try Sandbox("resolving-t02-symlink")
        defer { box.sweep() }
        let root = box.child("root")
        let outside = box.child("outside")
        let flowsBase = root.appending(path: "flows", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: flowsBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // flows/7f3a -> outside: the id is a perfectly valid segment, the directory it names is not ours.
        try FileManager.default.createSymbolicLink(
            at: flowsBase.appending(path: "7f3a", directoryHint: .notDirectory), withDestinationURL: outside)

        let paths = try layer(root)
        do {
            let url = try paths.url(for: FlowMetadata(flowID: "7f3a"))
            Issue.record("expected an escape refusal, resolved \(url.path)")
        } catch {
            guard case .escapesRoot = error else {
                Issue.record("expected escapesRoot, got \(error)")
                return
            }
        }
        // A sibling id that is a real directory still resolves.
        #expect(throws: Never.self) { try paths.url(for: FlowMetadata(flowID: "real")) }
    }

    @Test("T-02: a dangling symlink cannot be proved contained, so it is refused")
    func danglingSymlinkRefused() throws {
        let box = try Sandbox("resolving-t02-dangling")
        defer { box.sweep() }
        let root = box.child("root")
        let flowsBase = root.appending(path: "flows", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: flowsBase, withIntermediateDirectories: true)
        // The target does not exist: a write through this link would CREATE it outside the root.
        try FileManager.default.createSymbolicLink(
            at: flowsBase.appending(path: "7f3a", directoryHint: .notDirectory), withDestinationURL: box.child("not-yet-created"))
        let paths = try layer(root)
        #expect(throws: VirtualPathError.self) { try paths.url(for: FlowMetadata(flowID: "7f3a")) }
    }

    @Test("T-02: containment compares components, not text, and resolves symlinks on both sides")
    func containmentIsComponentwise() throws {
        let box = try Sandbox("resolving-t02-contain")
        defer { box.sweep() }
        let base = box.child("flow")
        let sibling = box.child("flows")
        let inside = base.appending(path: "a", directoryHint: .isDirectory).appending(path: "b.json", directoryHint: .notDirectory)
        #expect(PathContainment.isContained(base, in: base))
        #expect(PathContainment.isContained(inside, in: base))
        // `.../flows` is textually prefixed by `.../flow` — and is NOT inside it.
        #expect(!PathContainment.isContained(sibling, in: base))
        #expect(!PathContainment.isContained(base.deletingLastPathComponent(), in: base))
        let climbing = base.appending(path: PathVocabulary.parentComponent, directoryHint: .notDirectory).appending(path: "flows", directoryHint: .notDirectory)
        #expect(!PathContainment.isContained(climbing, in: base))
        #expect(throws: VirtualPathError.escapesRoot(path: sibling.path, root: base.path)) {
            try PathContainment.require(sibling, in: base)
        }
    }

    // MARK: T-03 — static placement + instance resolver

    @Test("T-03: a static placement and an instance resolver produce the id-dependent path")
    func idDependentPath() throws {
        let box = try Sandbox("resolving-t03")
        defer { box.sweep() }
        let paths = try layer(box.child("root"))
        let url = try paths.url(for: FlowMetadata(flowID: "7f3a"))
        #expect(url.lastPathComponent == "7f3a-metadata.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "7f3a")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "flows")
        #expect(try paths.virtualPath(for: FlowMetadata(flowID: "7f3a")).rendered()
            == ["flows", "7f3a", "7f3a-metadata.json"].joined(separator: Self.slash))
    }

    @Test("a single resource defaults its instance location to the static name")
    func singleResourceDefault() throws {
        let box = try Sandbox("resolving-single")
        defer { box.sweep() }
        let paths = try layer(box.child("root"))
        #expect(try paths.url(for: PlansLedger()).lastPathComponent == "plans.json")
        #expect(try PlansLedger().location() == VirtualPath(PlansLedger.placement.name))
    }

    @Test("a family of files is one typed enum, every case under its node")
    func familyOfFiles() throws {
        let box = try Sandbox("resolving-family")
        defer { box.sweep() }
        let paths = try layer(box.child("root"))
        let names = try QueueFile.allCases.map { try paths.url(for: $0).lastPathComponent }
        #expect(names == ["fast-pending.jsonl", "retry-pending.jsonl"])
        for file in QueueFile.allCases {
            #expect(try paths.url(for: file).deletingLastPathComponent().standardizedFileURL.path
                == paths.base(of: Tree.queue).standardizedFileURL.path)
        }
    }

    // MARK: Registry

    @Test("two kinds claiming one placement are refused with both names")
    func placementClash() throws {
        let error = #expect(throws: VirtualPathError.self) {
            try VirtualPathRegistry([PlansLedger.self, ImpostorLedger.self])
        }
        guard case .placementClash(let placement, let existing, let incoming)? = error else {
            Issue.record("expected placementClash, got \(String(describing: error))")
            return
        }
        #expect(placement == PlansLedger.placement.description)
        #expect(existing.contains("PlansLedger"))
        #expect(incoming.contains("ImpostorLedger"))
    }

    @Test("adding the same kind twice is a no-op, and the registry enumerates the tree")
    func registryIdempotentAndEnumerable() throws {
        let registry = try VirtualPathRegistry([PlansLedger.self, QueueFile.self, PlansLedger.self])
        #expect(registry.entries.count == 2)
        #expect(registry.entries.map(\.placement) == [PlansLedger.placement, QueueFile.placement])
        #expect(registry.contains(PlansLedger.self))
        #expect(!registry.contains(Stranger.self))
        #expect(registry.entries(on: Tree.queue).count == 1)
        #expect(registry.entries(on: Tree.flows).isEmpty)
    }

    @Test("an owner never added to the tree is refused by name — no second, invisible tree")
    func unregisteredOwnerRefused() throws {
        let box = try Sandbox("resolving-unregistered")
        defer { box.sweep() }
        let paths = try layer(box.child("root"))
        let error = #expect(throws: VirtualPathError.self) { try paths.url(for: Stranger()) }
        guard case .unregisteredOwner(let name)? = error else {
            Issue.record("expected unregisteredOwner, got \(String(describing: error))")
            return
        }
        #expect(name.contains("Stranger"))
    }

    @Test("registering returns a layer with the new kind and leaves the original alone")
    func registeringIsAValueCopy() throws {
        let box = try Sandbox("resolving-registering")
        defer { box.sweep() }
        let bare = try PathLayer(root: box.child("root"))
        let grown = try bare.registering([PlansLedger.self])
        #expect(bare.registry.entries.isEmpty)
        #expect(grown.registry.contains(PlansLedger.self))
        #expect(throws: Never.self) { try grown.url(for: PlansLedger()) }
    }

    // MARK: Nodes and roots

    @Test("a node served from an injected location moves without any owner changing (BR-RP-05)")
    func nodeRootOverride() throws {
        let box = try Sandbox("resolving-node-root")
        defer { box.sweep() }
        let flowsElsewhere = box.child("elsewhere")
        let paths = try layer(box.child("root"), nodeRoots: [Tree.flows: flowsElsewhere])
        let url = try paths.url(for: FlowMetadata(flowID: "7f3a"))
        #expect(PathContainment.isContained(url, in: flowsElsewhere))
        #expect(!PathContainment.isContained(url, in: paths.root))
        // Every other node still sits under the root.
        #expect(PathContainment.isContained(try paths.url(for: PlansLedger()), in: paths.root))
        // The virtual path — what an object store sees — does not change.
        #expect(try paths.virtualPath(for: FlowMetadata(flowID: "7f3a")).hasPrefix(VirtualPath(PathSegment(stringLiteral: "flows"))))
    }

    @Test("every declared tree node is distinct and resolves under the root")
    func declaredTreeNodesAreDistinctAndContained() throws {
        let box = try Sandbox("resolving-tree-cases")
        defer { box.sweep() }
        let paths = try layer(box.child("root"))
        #expect(VirtualNodeNamingRatchet.violations(of: Tree.self, in: paths).isEmpty)
    }

    @Test("resolution is resolve-only: it creates nothing")
    func resolveOnly() throws {
        let box = try Sandbox("resolving-resolve-only")
        defer { box.sweep() }
        let root = box.child("never-created")
        let paths = try layer(root)
        let url = try paths.url(for: FlowMetadata(flowID: "7f3a"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("a layer needs a file URL root")
    func rootMustBeFileURL() throws {
        let web = try webURL()
        #expect(throws: VirtualPathError.rootNotFileURL(web.absoluteString)) { try PathLayer(root: web) }
        let box = try Sandbox("resolving-file-url")
        defer { box.sweep() }
        #expect(throws: VirtualPathError.rootNotFileURL(web.absoluteString)) {
            try PathLayer(root: box.dir, nodeRoots: [Tree.flows: web])
        }
    }

    // MARK: Settings strings

    @Test("a root from settings must be absolute: relative, blank, padded and home-shorthand roots are refused",
          arguments: PathResolvingTests.badRoots)
    func badRootRefused(_ raw: String) {
        let configuration = PathLayerConfiguration(root: raw)
        #expect(throws: VirtualPathError.rootNotAbsolute(raw)) { try PathLayer(configuration: configuration) }
    }

    private static let badRoots: [String] = [
        ["relative", "dir"].joined(separator: slash),
        "",
        "   ",
        PathVocabulary.homeShorthand + slash + "data",
        PathVocabulary.homeShorthand,
        PathVocabulary.currentComponent,
    ]

    @Test("an absolute settings root builds the layer, node overrides included")
    func configurationBuildsLayer() throws {
        let box = try Sandbox("resolving-configuration")
        defer { box.sweep() }
        let configuration = PathLayerConfiguration(
            root: box.child("root").path,
            nodeRoots: [
                "flows": box.child("flows-root").path,
                ["state", "ai-routing"].joined(separator: Self.slash): box.child("routing").path,
            ])
        let paths = try PathLayer(configuration: configuration, registry: VirtualPathRegistry(allOwners))
        #expect(PathContainment.isContained(try paths.url(for: FlowMetadata(flowID: "1")), in: box.child("flows-root")))
        #expect(paths.base(of: Tree.aiRouting).lastPathComponent == "routing")
        #expect(PathContainment.isContained(try paths.url(for: PlansLedger()), in: box.child("root")))
    }

    @Test("a node override that is itself relative is refused")
    func relativeNodeRootRefused() {
        let configuration = PathLayerConfiguration(
            root: PathVocabulary.filesystemRoot, nodeRoots: ["flows": ["rel", "flows"].joined(separator: Self.slash)])
        #expect(throws: VirtualPathError.self) { try PathLayer(configuration: configuration) }
    }

    @Test("the configuration is a plain Codable settings shape")
    func configurationCodable() throws {
        let configuration = PathLayerConfiguration(
            root: PathVocabulary.filesystemRoot, nodeRoots: ["flows": PathVocabulary.filesystemRoot])
        let data = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(PathLayerConfiguration.self, from: data) == configuration)
    }

    // MARK: Object-store form

    @Test("the same owner addresses an object store from the same components")
    func addressFromSameComponents() throws {
        let box = try Sandbox("resolving-address")
        defer { box.sweep() }
        let paths = try layer(box.child("root"))
        let owner = FlowMetadata(flowID: "7f3a")
        let address = try paths.address(for: owner, bucket: "evidence", nodeID: "mac-a")
        #expect(address.path == (try paths.virtualPath(for: owner)))
        #expect(address.renderedKey() == ["mac-a", "flows", "7f3a", "7f3a-metadata.json"].joined(separator: Self.slash))
        #expect(address.rendered() == ["evidence", "mac-a", "flows", "7f3a", "7f3a-metadata.json"].joined(separator: Self.slash))
        // And the local form is the same components under the root.
        let local = try paths.url(for: owner)
        #expect(local.pathComponents.suffix(3).map { $0 } == ["flows", "7f3a", "7f3a-metadata.json"])
    }

    @Test("T-06 at the addressing level: three node ids never share a key for one owner")
    func threeNodesNeverCollide() throws {
        let box = try Sandbox("resolving-nodes")
        defer { box.sweep() }
        let paths = try layer(box.child("root"))
        let owner = FlowMetadata(flowID: "7f3a")
        let keys = try ["mac-a", "mac-b", "mac-c"].map {
            try paths.address(for: owner, bucket: "evidence", nodeID: NodeID($0)).renderedKey()
        }
        #expect(Set(keys).count == 3)
    }

    @Test("an address for an unregistered owner is refused too")
    func addressNeedsRegistration() throws {
        let box = try Sandbox("resolving-address-unreg")
        defer { box.sweep() }
        let paths = try layer(box.child("root"))
        #expect(throws: VirtualPathError.self) {
            try paths.address(for: Stranger(), bucket: "evidence", nodeID: "mac-a")
        }
    }

    // MARK: TestRunRoot

    @Test("the test root nests .tests, the branch slug, the correlation id and the target, and prints its reference")
    func testRunRootLayout() throws {
        let box = try Sandbox("resolving-test-run-root")
        defer { box.sweep() }
        let branch = ["epic", "d3f8a1b2-resource-layer"].joined(separator: Self.slash)
        let run = try TestRunRoot(base: box.dir, branch: branch, correlationID: "01a18ddd-5e4a", target: "CoreKitTests")
        #expect(run.url.pathComponents.suffix(4).map { $0 }
            == [".tests", "epic-d3f8a1b2-resource-layer", "01a18ddd-5e4a", "CoreKitTests"])
        #expect(run.reference == ["epic-d3f8a1b2-resource-layer", "01a18ddd-5e4a"].joined(separator: Self.slash))
        #expect(PathContainment.isContained(run.url, in: box.dir))
    }

    @Test("two runs of one target on one device never share a folder")
    func runsAreIsolated() throws {
        let box = try Sandbox("resolving-runs")
        defer { box.sweep() }
        let one = try TestRunRoot(base: box.dir, branch: "main", correlationID: "corr-1", target: "T")
        let two = try TestRunRoot(base: box.dir, branch: "main", correlationID: "corr-2", target: "T")
        #expect(one.url != two.url)
        // A rebase or rename changes the readable branch segment, never the identity.
        let renamed = try TestRunRoot(base: box.dir, branch: "other", correlationID: "corr-1", target: "T")
        #expect(renamed.correlationID == one.correlationID)
    }

    @Test("a correlation id is an identity: a hostile one is refused, never slugged")
    func correlationIDIsValidatedNotSlugged() throws {
        let box = try Sandbox("resolving-corr")
        defer { box.sweep() }
        let hostile = [PathVocabulary.parentComponent, "x"].joined(separator: Self.slash)
        #expect(throws: VirtualPathError.separatorInSegment(hostile)) {
            try TestRunRoot(base: box.dir, branch: "main", correlationID: hostile, target: "T")
        }
        let web = try webURL()
        #expect(throws: VirtualPathError.rootNotFileURL(web.absoluteString)) {
            try TestRunRoot(base: web, branch: "main", correlationID: "c", target: "T")
        }
    }
}
