//
//  VirtualPathOwning.swift
//  CoreKit
//
//  The contract a typed document, datum or resource conforms to so that IT
//  declares where it lives — and nobody else restates it. A redesign of the
//  `ShikkiResourceFile` / `ShikkiPathResolving` shape that preceded it, not a
//  lift of it: the owner declares its placement, the resolver is generic.
//

import Foundation

// MARK: - VirtualNode

/// A scope-kind in the virtual tree: the directory-like home a family of
/// owners shares (`flows`, `state`, `queue`, `run`, `config`, ...).
///
/// A node is a VALUE, not a case of a closed enum (BR-RP-05): a closed enum of
/// roots would be a second source of truth for roots that are a
/// setting (`paths.flows_root`) and could not hold a layout a project grows
/// into. The scope-kind skeleton a project defines is a set of `static let`
/// nodes on its own namespace; CoreKit does not know any of them.
///
/// A node is located BELOW the layer's root by default; a layer can be told to
/// serve a node from somewhere else entirely (the injected `nodeRoots` of
/// ``PathLayer``) — which is how a settings value moves one node without any
/// owner's declaration changing.
public struct VirtualNode: Hashable, Sendable, Codable, CustomStringConvertible {

    /// Where the node sits below the root, as components.
    public let path: VirtualPath

    /// The root itself: owners declared directly on it have no scope-kind folder.
    public static let root = VirtualNode(path: .empty)

    public init(path: VirtualPath) {
        self.path = path
    }

    /// A top-level node: one component below the root.
    public init(_ name: PathSegment) {
        path = VirtualPath(name)
    }

    /// A node nested inside this one (`state` → `state/ai-routing`).
    public func child(_ name: PathSegment) -> VirtualNode {
        VirtualNode(path: path.appending(name))
    }

    public var description: String { path.isEmpty ? "(root)" : path.description }
}

// MARK: - VirtualPlacement

/// The STATIC half of an owner's declaration: the kind of resource it is —
/// its scope-kind node and its name.
///
/// The registry keys on it (two owner kinds cannot claim one placement) and
/// the default instance location is just the name. For a family of files
/// (a `CaseIterable` enum of queue files) the name is the family's, and each
/// case overrides ``VirtualPathOwning/location()`` with its own.
public struct VirtualPlacement: Hashable, Sendable, Codable, CustomStringConvertible {
    public let node: VirtualNode
    public let name: PathSegment

    public init(node: some VirtualNodeConvertible, name: PathSegment) {
        self.node = node.node
        self.name = name
    }

    /// Node and name as one virtual path.
    public var path: VirtualPath { node.path.appending(name) }

    public var description: String { path.description }
}

// MARK: - VirtualPathOwning

/// A typed thing that OWNS its path (BR-RP-02).
///
/// ```swift
/// // A single resource: the static placement is the whole declaration.
/// struct PlansLedger: VirtualPathOwning {
///     static let placement = VirtualPlacement(node: Tree.state, name: "plans.json")
/// }
///
/// // An id-dependent one: the instance resolver gives the concrete location —
/// // here the id is a folder AND part of the file name.
/// struct FlowMetadata: VirtualPathOwning {
///     static let placement = VirtualPlacement(node: Tree.flows, name: "metadata.json")
///     let flowID: String
///
///     func location() throws(VirtualPathError) -> VirtualPath {
///         VirtualPath(try PathSegment(flowID), try PathSegment("\(flowID)-metadata.json"))
///     }
/// }
///
/// let url = try paths.url(for: FlowMetadata(flowID: "7f3a"))   // <flows root>/7f3a/7f3a-metadata.json
/// ```
///
/// What an owner does NOT declare: a root. The root is injected into the
/// resolver, so prod and test differ by that one value and no owner's
/// declaration ever changes (BR-RP-03).
public protocol VirtualPathOwning: Sendable {

    /// The kind's node and name. STATIC: the registry reads it without an instance.
    static var placement: VirtualPlacement { get }

    /// Where THIS instance lives, as components below ``placement`` `.node`.
    /// The default is the placement's name — right for every resource that is
    /// not id-dependent. Throwing, because the components of an id-dependent
    /// resource come from data and a segment can refuse (a `..` in an id).
    func location() throws(VirtualPathError) -> VirtualPath
}

extension VirtualPathOwning {
    public func location() throws(VirtualPathError) -> VirtualPath {
        VirtualPath(Self.placement.name)
    }
}
