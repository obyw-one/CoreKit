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
/// Checks: the parent graph is acyclic (reported, never evaluated, so a loop
/// cannot trap the suite), no two cases name one node, and every node's base
/// resolves under `layer.root`. Walking `allCases` also evaluates each raw
/// value as a ``PathSegment``, so an invalid name dies here, not in a consumer.
public enum VirtualNodeNamingRatchet {

    /// - Returns: one line per parent cycle, per collision (two cases naming
    ///   one node) and per node whose base escapes `layer.root`. Empty means clean.
    public static func violations<Tree: VirtualNodeNaming>(
        of _: Tree.Type, in layer: some PathResolving
    ) -> [String] {
        var seen: [VirtualNode: Tree] = [:]
        var found: [String] = []
        for tree in Tree.allCases {
            // A cyclic case has no node to evaluate: report it and move on.
            guard tree.ancestry != nil else {
                found.append("\(Tree.self).\(tree): parent chain loops")
                continue
            }
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

    /// The composed tree: the registry must build (no collision across enums, no
    /// cycle, every mount resolving to a declared node) and every declared node must resolve under `layer.root`.
    public static func violations(
        composing trees: [any VirtualNodeNaming.Type], in layer: some PathResolving
    ) -> [String] {
        let registry: VirtualNodeRegistry
        do { registry = try VirtualNodeRegistry(trees) } catch { return [error.description] }
        return registry.declared.compactMap { entry in
            PathContainment.isContained(layer.base(of: entry.node), in: layer.root)
                ? nil : "\(entry.name): base of \(entry.node) escapes root \(layer.root.path)"
        }
    }
}
