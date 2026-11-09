//
//  VirtualNodeRegistry.swift
//  CoreKit
//
//  The full virtual resource tree, composed from every naming enum.
//  Sibling of `VirtualPathRegistry` (which holds OWNER types): this holds the
//  NODE vocabularies. Pure: no I/O, no platform import.
//

import Foundation

// MARK: - VirtualNodeRegistry

/// Composes any number of ``VirtualNodeNaming`` enums into ONE tree rooted at
/// ``VirtualNode/root``.
///
/// `parent: Self?` is compile-checked but stays inside one enum, so a forest of
/// enums (the platform's, an app's, a kit's) is disconnected by itself. Each
/// enum's ``VirtualNodeNaming/mount`` says where its roots attach; this
/// registry joins them by node path. A mount no enum declares is an implicit
/// node and is drawn as such.
///
/// Two enums naming the same node, or a cyclic enum, is refused at
/// construction rather than drawn wrongly.
public struct VirtualNodeRegistry: Sendable {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Two cases (possibly of different enums) name one node.
        case collision(node: VirtualNode, first: String, second: String)
        /// The case's parent chain loops.
        case cyclic(String)

        public var description: String {
            switch self {
            case .collision(let node, let first, let second): "\(first) and \(second) both name node \(node)"
            case .cyclic(let name): "\(name): parent chain loops"
            }
        }
    }

    /// Every declared node with the case that declares it ("Tree.state"), in registration order.
    public let declared: [(node: VirtualNode, name: String)]

    private let children: [VirtualPath: [PathSegment]]
    private let owners: [VirtualNode: String]

    public init(_ trees: [any VirtualNodeNaming.Type]) throws(Failure) {
        var declared: [(node: VirtualNode, name: String)] = []
        for tree in trees { try Self.collect(tree, into: &declared) }
        var owners: [VirtualNode: String] = [:]
        var children: [VirtualPath: [PathSegment]] = [:]
        for (node, name) in declared {
            if let first = owners[node] { throw .collision(node: node, first: first, second: name) }
            owners[node] = name
            var prefix = VirtualPath.empty
            for segment in node.path.segments {
                if !(children[prefix] ?? []).contains(segment) { children[prefix, default: []].append(segment) }
                prefix = prefix.appending(segment)
            }
        }
        self.declared = declared
        self.owners = owners
        self.children = children
    }

    private static func collect<Tree: VirtualNodeNaming>(
        _: Tree.Type, into declared: inout [(node: VirtualNode, name: String)]
    ) throws(Failure) {
        for tree in Tree.allCases {
            guard tree.ancestry != nil else { throw .cyclic("\(Tree.self).\(tree)") }
            declared.append((tree.node, "\(Tree.self).\(tree)"))
        }
    }

    /// The whole tree from the root, one node per line; with each node's
    /// resolved base under `layer` (a node served elsewhere shows where).
    /// A node no enum declares, only a mount point, is marked `(mount)`.
    public func rendered(resolving layer: some PathResolving) -> String {
        var lines: [String] = []
        func label(_ path: VirtualPath, _ name: String) -> String {
            let node = VirtualNode(path: path)
            let suffix = owners[node] == nil ? " (mount)" : ""
            return "\(name)\(suffix)  →  \(layer.base(of: node).path)"
        }
        func walk(_ path: VirtualPath, prefix: String, connector: String, childPrefix: String, name: String) {
            lines.append(prefix + connector + label(path, name))
            let kids = children[path] ?? []
            for (index, kid) in kids.enumerated() {
                let last = index == kids.count - 1
                walk(path.appending(kid), prefix: childPrefix, connector: last ? "└── " : "├── ",
                     childPrefix: childPrefix + (last ? "    " : "│   "), name: kid.description)
            }
        }
        walk(.empty, prefix: "", connector: "", childPrefix: "", name: "(root)")
        return lines.joined(separator: "\n")
    }
}
