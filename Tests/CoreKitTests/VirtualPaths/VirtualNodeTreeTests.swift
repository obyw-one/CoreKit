import CoreKit
import CoreKitTestSupport
import Foundation
import Testing

// MARK: - Fixtures

private enum Tree: String, VirtualNodeNaming {
    case flows, state, queue
    case aiRouting = "ai-routing"
    case models
    var parent: Tree? {
        switch self {
        case .aiRouting: .state
        case .models: .aiRouting
        default: nil
        }
    }
}

/// Identical structure to ``Renamed``; only the parent's RAW VALUE differs.
private enum Original: String, VirtualNodeNaming {
    case state
    case routing = "ai-routing"
    var parent: Original? { self == .routing ? .state : nil }
}

private enum Renamed: String, VirtualNodeNaming {
    case state = "core-state"
    case routing = "ai-routing"
    var parent: Renamed? { self == .routing ? .state : nil }
}

private enum SelfParent: String, VirtualNodeNaming {
    case ok, loop
    var parent: SelfParent? { self == .loop ? .loop : nil }
}

private enum TwoCycle: String, VirtualNodeNaming {
    case root, a, b
    var parent: TwoCycle? {
        switch self {
        case .a: .b
        case .b: .a
        case .root: nil
        }
    }
}

/// A second enum, mounted under a node the first one owns.
private enum App: String, VirtualNodeNaming {
    case cache, logs
    case hot
    var parent: App? { self == .hot ? .cache : nil }
    static var mount: VirtualNode { VirtualNode("state").child("ai-routing") }
}

/// Declares the `plugins` node that ``Plugin`` is mounted under.
private enum PluginArea: String, VirtualNodeNaming {
    case plugins
}

/// Mounted under ``PluginArea/plugins``.
private enum Plugin: String, VirtualNodeNaming {
    case data
    static var mount: VirtualNode { PluginArea.plugins.node }
}

private enum Clash: String, VirtualNodeNaming {
    case flows
}

private struct Sandbox {
    let scratch = TestScratch.forPackage()
    let dir: URL
    init(_ scope: String) throws { dir = try scratch.makeScratchDir(scope: scope) }
    func sweep() { try? scratch.removeScratchDir(dir) }
}

// MARK: - VirtualNodeTreeTests

@Suite("VirtualNodeNaming — parent by case, the tree reconstructed from it")
struct VirtualNodeTreeTests {

    @Test("a nested node equals the chained node, and a top-level node is one segment")
    func nodeEquivalence() {
        #expect(Tree.aiRouting.node == VirtualNode("state").child("ai-routing"))
        #expect(Tree.models.node == VirtualNode("state").child("ai-routing").child("models"))
        #expect(Tree.flows.node == VirtualNode("flows"))
        #expect(Tree.models.node.path.segments.count == 3)
    }

    @Test("renaming a parent's raw value moves the child's node and its resolved base with it")
    func renamePropagates() throws {
        let box = try Sandbox("node-tree-rename")
        defer { box.sweep() }
        let before = try PathLayer(root: box.dir, registry: VirtualPathRegistry([]))
        #expect(Original.routing.node == VirtualNode("state").child("ai-routing"))
        #expect(Renamed.routing.node == VirtualNode("core-state").child("ai-routing"))
        #expect(before.base(of: Original.routing).path.hasSuffix("/state/ai-routing"))
        #expect(before.base(of: Renamed.routing).path.hasSuffix("/core-state/ai-routing"))
    }

    @Test("roots, children and depth are reconstructed from allCases and parent")
    func reconstruction() {
        let tree = VirtualNodeTree<Tree>()
        #expect(tree.roots == [.flows, .state, .queue])
        #expect(tree.children(of: .state) == [.aiRouting])
        #expect(tree.children(of: .aiRouting) == [.models])
        #expect(tree.children(of: .flows).isEmpty)
        #expect(tree.depth(of: .state) == 0)
        #expect(tree.depth(of: .models) == 2)
        #expect(tree.cyclic.isEmpty)
    }

    @Test("the tree renders with box-drawing connectors")
    func rendering() {
        #expect(VirtualNodeTree<Tree>().rendered() == """
            flows
            state
            └── ai-routing
                └── models
            queue
            """)
    }

    @Test("rendering with a layer shows where each node resolves, a served-elsewhere node included")
    func renderingResolved() throws {
        let box = try Sandbox("node-tree-resolved")
        defer { box.sweep() }
        let elsewhere = box.dir.appending(path: "elsewhere", directoryHint: .isDirectory)
        let layer = try PathLayer(
            root: box.dir.appending(path: "root", directoryHint: .isDirectory),
            nodeRoots: [VirtualNode("queue"): elsewhere], registry: VirtualPathRegistry([]))
        let lines = VirtualNodeTree<Tree>().rendered(resolving: layer).split(separator: "\n").map(String.init)
        #expect(lines.count == 5)
        #expect(lines[0].hasPrefix("flows  →  ") && lines[0].hasSuffix("/root/flows"))
        #expect(lines[2].hasPrefix("└── ai-routing  →  ") && lines[2].hasSuffix("/root/state/ai-routing"))
        #expect(lines[3].hasPrefix("    └── models  →  ") && lines[3].hasSuffix("/root/state/ai-routing/models"))
        #expect(lines[4].hasSuffix("/elsewhere"))
    }

    @Test("a self-parent has no ancestry, is reported, and is not drawn")
    func selfParent() throws {
        let box = try Sandbox("node-tree-self")
        defer { box.sweep() }
        #expect(SelfParent.loop.ancestry == nil)
        #expect(SelfParent.ok.ancestry == [.ok])
        let layer = try PathLayer(root: box.dir, registry: VirtualPathRegistry([]))
        #expect(VirtualNodeNamingRatchet.violations(of: SelfParent.self, in: layer) == ["SelfParent.loop: parent chain loops"])
        #expect(VirtualNodeTree<SelfParent>().cyclic == [.loop])
    }

    @Test("a two-case cycle is detected on both members and the innocent root is untouched")
    func twoCaseCycle() throws {
        let box = try Sandbox("node-tree-cycle")
        defer { box.sweep() }
        #expect(TwoCycle.a.ancestry == nil)
        #expect(TwoCycle.b.ancestry == nil)
        let layer = try PathLayer(root: box.dir, registry: VirtualPathRegistry([]))
        let found = VirtualNodeNamingRatchet.violations(of: TwoCycle.self, in: layer)
        #expect(found == ["TwoCycle.a: parent chain loops", "TwoCycle.b: parent chain loops"])
        let tree = VirtualNodeTree<TwoCycle>()
        #expect(tree.roots == [.root])
        #expect(tree.cyclic == [.a, .b])
    }

    #if os(macOS) || os(Linux)
    @Test("evaluating the node of a cyclic case fails fast instead of hanging")
    func nodeOfCycleTraps() async {
        await #expect(processExitsWith: .failure) { _ = TwoCycle.a.node }
        await #expect(processExitsWith: .failure) { _ = SelfParent.loop.node }
    }
    #endif

    @Test("the sound tree passes the ratchet")
    func soundTreeIsClean() throws {
        let box = try Sandbox("node-tree-clean")
        defer { box.sweep() }
        let layer = try PathLayer(root: box.dir, registry: VirtualPathRegistry([]))
        #expect(VirtualNodeNamingRatchet.violations(of: Tree.self, in: layer).isEmpty)
    }

    // MARK: - Composition across enums

    @Test("enums compose into ONE tree from the root, a mount point joining a child enum under a parent enum's node")
    func composedFromRoot() throws {
        let box = try Sandbox("node-tree-forest")
        defer { box.sweep() }
        let layer = try PathLayer(
            root: box.dir.appending(path: "root", directoryHint: .isDirectory), registry: VirtualPathRegistry([]))
        let registry = try VirtualNodeRegistry([Tree.self, App.self, PluginArea.self, Plugin.self])
        #expect(App.hot.node == VirtualNode("state").child("ai-routing").child("cache").child("hot"))
        let lines = registry.rendered(resolving: layer).split(separator: "\n").map(String.init)
        #expect(lines[0].hasPrefix("(root)  →  ") && lines[0].hasSuffix("/root"))
        let names = lines.map { $0.components(separatedBy: "  →  ")[0] }
        #expect(names == [
            "(root)", "├── flows", "├── state", "│   └── ai-routing", "│       ├── models",
            "│       ├── cache", "│       │   └── hot", "│       └── logs", "├── queue",
            "└── plugins", "    └── data",
        ])
        #expect(lines[4].hasSuffix("/root/state/ai-routing/models"))
        #expect(!lines.contains { $0.contains("(mount)") })
    }

    @Test("a mount no registered enum declares is refused, naming the enum and the mount; order is irrelevant")
    func unresolvedMountRefused() throws {
        let failure = #expect(throws: VirtualNodeRegistry.Failure.self) {
            try VirtualNodeRegistry([Tree.self, Plugin.self])
        }
        #expect(failure == .unresolvedMount(enumName: "Plugin", mount: VirtualNode("plugins")))
        let message = failure?.description ?? ""
        #expect(message.contains("Plugin") && message.contains("plugins") && message.contains("register the enum"))
        // The owner registered AFTER the mounted enum still resolves it.
        #expect(throws: Never.self) { try VirtualNodeRegistry([Plugin.self, PluginArea.self]) }
        let box = try Sandbox("node-tree-unresolved-ratchet")
        defer { box.sweep() }
        let layer = try PathLayer(root: box.dir, registry: VirtualPathRegistry([]))
        let found = VirtualNodeNamingRatchet.violations(composing: [Tree.self, Plugin.self], in: layer)
        #expect(found.count == 1 && found[0].contains("Plugin") && found[0].contains("plugins"))
    }

    @Test("two enums naming one node, or a cyclic enum, are refused when composing")
    func compositionRefuses() throws {
        #expect(throws: VirtualNodeRegistry.Failure.self) { try VirtualNodeRegistry([Tree.self, Clash.self]) }
        #expect(throws: VirtualNodeRegistry.Failure.self) { try VirtualNodeRegistry([TwoCycle.self]) }
        let box = try Sandbox("node-tree-forest-ratchet")
        defer { box.sweep() }
        let layer = try PathLayer(root: box.dir, registry: VirtualPathRegistry([]))
        #expect(VirtualNodeNamingRatchet.violations(composing: [Tree.self, App.self, PluginArea.self, Plugin.self], in: layer).isEmpty)
        let found = VirtualNodeNamingRatchet.violations(composing: [Tree.self, Clash.self], in: layer)
        #expect(found.count == 1 && found[0].contains("Tree.flows and Clash.flows both name node flows"))
    }
}
