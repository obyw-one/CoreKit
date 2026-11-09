import CoreKit
import Foundation

// MARK: - VirtualNodeNamingRatchet

/// The one check every ``VirtualNodeNaming`` enum is held to, written once.
///
/// Walks `allCases` and reports every violation as a string; empty means the
/// tree is sound. Consumers assert `violations(of: Tree.self, in: layer)` is
/// empty instead of writing their own per-tree test. Like the other ratchets
/// here it imports no test framework, so every kit's suite can call it.
///
/// Walking `allCases` also evaluates every case's ``VirtualNodeConvertible/node``,
/// which is what closes the one cost of the trapping default: `case bad = "a/b"`
/// compiles, and would die at first use in a consumer. Here it dies in the suite.
public enum VirtualNodeNamingRatchet {

    /// - Returns: one line per collision (two cases naming one node) and per
    ///   node whose base escapes `layer.root`. Empty means clean.
    public static func violations<Tree: VirtualNodeNaming>(
        of _: Tree.Type, in layer: some PathResolving
    ) -> [String] {
        var seen: [VirtualNode: Tree] = [:]
        var found: [String] = []
        for tree in Tree.allCases {
            let node = tree.node
            if let first = seen[node] {
                found.append("\(Tree.self).\(first) and .\(tree) both name node \(node)")
            } else {
                seen[node] = tree
            }
            if !PathContainment.isContained(layer.base(of: node), in: layer.root) {
                found.append("\(Tree.self).\(tree): base of \(node) escapes root \(layer.root.path)")
            }
        }
        return found
    }
}
