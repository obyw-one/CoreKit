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
/// registry joins them by node path.
///
/// STRICT: a mount must be ``VirtualNode/root`` or a node some registered enum
/// declares. An enum mounted below another's node is therefore REQUIRED to be
/// registered together with it (order is irrelevant). A directory no type owns
/// is exactly the unowned-string problem this layer exists to abolish, so there
/// is no implicit node and no "external" escape hatch.
///
/// Two enums naming the same node, a cyclic enum, or an unresolvable mount is
/// refused at construction rather than drawn wrongly.
public struct VirtualNodeRegistry: Sendable {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Two cases (possibly of different enums) name one node.
        case collision(node: VirtualNode, first: String, second: String)
        /// The case's parent chain loops.
        case cyclic(String)
        /// The enum's `mount` names a node no registered enum declares.
        case unresolvedMount(enumName: String, mount: VirtualNode)

        public var description: String {
            switch self {
            case .collision(let node, let first, let second): "\(first) and \(second) both name node \(node)"
            case .cyclic(let name): "\(name): parent chain loops"
            case .unresolvedMount(let enumName, let mount):
                "\(enumName): mount \(mount) is declared by no registered enum; register the enum that owns it"
            }
        }
    }

    /// Every declared node with the case that declares it ("Tree.state"), in registration order.
    public let declared: [(node: VirtualNode, name: String)]

    private let children: [VirtualPath: [PathSegment]]
    private let owners: [VirtualNode: String]

    public init(_ trees: [any VirtualNodeNaming.Type]) throws(Failure) {
        var declared: [(node: VirtualNode, name: String)] = []
        var mounts: [(enumName: String, mount: VirtualNode)] = []
        for tree in trees { try Self.collect(tree, into: &declared, mounts: &mounts) }
        var owners: [VirtualNode: String] = [:]
        var children: [VirtualPath: [PathSegment]] = [:]
        for (node, name) in declared {
            if let first = owners[node] { throw .collision(node: node, first: first, second: name) }
            owners[node] = name
        }
        // After ALL enums are collected, so registration order cannot matter.
        for (enumName, mount) in mounts where mount != .root && owners[mount] == nil {
            throw .unresolvedMount(enumName: enumName, mount: mount)
        }
        for (node, _) in declared {
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
        _: Tree.Type, into declared: inout [(node: VirtualNode, name: String)],
        mounts: inout [(enumName: String, mount: VirtualNode)]
    ) throws(Failure) {
        mounts.append(("\(Tree.self)", Tree.mount))
        for tree in Tree.allCases {
            guard tree.ancestry != nil else { throw .cyclic("\(Tree.self).\(tree)") }
            declared.append((tree.node, "\(Tree.self).\(tree)"))
        }
    }

    /// The whole tree from the root, one node per line; with each node's
    /// resolved base under `layer` (a node served elsewhere shows where).
    /// Only declared nodes are drawn; the root, which no enum declares, is labelled `(root)`.
    public func rendered(resolving layer: some PathResolving) -> String {
        var lines: [String] = []
        func label(_ path: VirtualPath, _ name: String) -> String {
            return "\(name)  →  \(layer.base(of: VirtualNode(path: path)).path)"
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
