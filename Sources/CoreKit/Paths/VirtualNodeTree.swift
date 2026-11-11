//
//  VirtualNodeTree.swift
//  CoreKit
//
//  The hierarchy a `VirtualNodeNaming` enum declares, reconstructed from
//  `allCases` and each case's `parent`, and drawn. Pure: no I/O, no platform
//  import. CoreKit sits under the design and tooling layers, so it carries its
//  own minimal drawing rather than depending upward on one.
//

import Foundation

// MARK: - VirtualNodeTree

/// The typed hierarchy of one ``VirtualNodeNaming`` enum.
///
/// Order is declaration order (`allCases`), so a rendering is stable. Cases
/// whose parent chain loops are unreachable from any root and are reported in
/// ``cyclic`` instead of being drawn (or looped on).
public struct VirtualNodeTree<Tree: VirtualNodeNaming> {

    /// Top-level cases (no parent), in declaration order.
    public let roots: [Tree]

    /// Cases whose parent chain loops.
    public let cyclic: [Tree]

    private let childrenByParent: [String: [Tree]]

    public init() {
        var children: [String: [Tree]] = [:]
        var roots: [Tree] = []
        var cyclic: [Tree] = []
        for tree in Tree.allCases {
            if tree.ancestry == nil {
                cyclic.append(tree)
            } else if let parent = tree.parent {
                children[parent.rawValue, default: []].append(tree)
            } else {
                roots.append(tree)
            }
        }
        self.roots = roots
        self.cyclic = cyclic
        childrenByParent = children
    }

    /// Direct children of `tree`, in declaration order.
    public func children(of tree: Tree) -> [Tree] { childrenByParent[tree.rawValue] ?? [] }

    /// Parents between `tree` and its root: 0 for a root, `nil` when cyclic.
    public func depth(of tree: Tree) -> Int? { tree.ancestry.map { $0.count - 1 } }

    /// The tree as text, one node per line:
    ///
    /// ```
    /// flows
    /// state
    /// └── ai-routing
    /// queue
    /// ```
    public func rendered() -> String { render { _ in nil } }

    /// The same tree with where each node actually lands: its resolved base
    /// under `layer`, including any node the layer serves from elsewhere.
    public func rendered(resolving layer: some PathResolving) -> String {
        render { layer.base(of: $0).path }
    }

    private func render(annotation: (Tree) -> String?) -> String {
        var lines: [String] = []
        func line(_ tree: Tree, prefix: String, connector: String) -> String {
            let label = tree.rawValue
            return prefix + connector + (annotation(tree).map { "\(label)  →  \($0)" } ?? label)
        }
        func walk(_ tree: Tree, prefix: String, isLast: Bool, isRoot: Bool) {
            let connector = isRoot ? "" : (isLast ? "└── " : "├── ")
            lines.append(line(tree, prefix: prefix, connector: connector))
            let kids = children(of: tree)
            let childPrefix = isRoot ? prefix : prefix + (isLast ? "    " : "│   ")
            for (index, kid) in kids.enumerated() {
                walk(kid, prefix: childPrefix, isLast: index == kids.count - 1, isRoot: false)
            }
        }
        for root in roots { walk(root, prefix: "", isLast: true, isRoot: true) }
        for loop in cyclic { lines.append("\(loop.rawValue)  (cyclic parent chain, not drawn)") }
        return lines.joined(separator: "\n")
    }
}
