//
//  VirtualNodeConvertible.swift
//  CoreKit
//
//  How a project names its scope-kind nodes without restating them: one
//  `String` enum whose case names ARE the node names. Lives beside
//  `VirtualPathOwning.swift`, not in it, because it is a separate contract
//  (naming) from the one that file defines (placement).
//

import Foundation

// MARK: - VirtualNodeConvertible

/// Anything that denotes a ``VirtualNode``.
///
/// Every CoreKit API that takes a node takes `some VirtualNodeConvertible`, so
/// a call site passes `Tree.state` and never `Tree.state.node`. Swift has no
/// user-defined implicit conversion; widening the parameter is the only way
/// to get that. A bare ``VirtualNode`` conforms and returns itself, so existing
/// callers are unchanged.
public protocol VirtualNodeConvertible {
    var node: VirtualNode { get }
}

extension VirtualNode: VirtualNodeConvertible {
    public var node: VirtualNode { self }
}

// MARK: - VirtualNodeNaming

/// A closed, named set of nodes: the raw string is ONE path segment, and a
/// nested node names its parent by CASE.
///
/// ```swift
/// enum Tree: String, VirtualNodeNaming {
///     case flows, state, queue
///     case aiRouting = "ai-routing"
///     var parent: Tree? { self == .aiRouting ? .state : nil }
/// }
/// ```
///
/// There is no separator anywhere and no string naming another case. The
/// parent is REFERENCED, so the compiler checks it exists and a rename of
/// `.state` moves `.aiRouting` with it. A slash in a raw value could only
/// prove the string was a legal path, never that it named a declared node.
///
/// Because the conformer is `CaseIterable` and every case states its parent,
/// the whole hierarchy is reconstructible: see ``VirtualNodeTree``.
///
/// A raw value is a segment, so it is validated by ``PathSegment``, which
/// TRAPS on an invalid literal: a name written in source is a programmer
/// error, not runtime input. ``node`` also traps, with a message, on a parent
/// cycle (see ``ancestry``); `VirtualNodeNamingRatchet` reports both in the
/// suite before a consumer meets them.
public protocol VirtualNodeNaming: RawRepresentable, CaseIterable, VirtualNodeConvertible
where RawValue == String {

    /// The node this one is nested in; `nil` for a top-level node (default).
    var parent: Self? { get }

    /// The node this enum's ROOT cases hang from (default: the tree root).
    ///
    /// `parent` is `Self?`, so it cannot cross enums; the mount is how one enum
    /// attaches under a node another enum (or nobody) owns, so a consumer's
    /// tree can sit under a node the platform owns. `VirtualNodeRegistry`
    /// composes every enum into the one tree rooted at ``VirtualNode/root``.
    static var mount: VirtualNode { get }
}

extension VirtualNodeNaming {

    public var parent: Self? { nil }

    public static var mount: VirtualNode { .root }

    /// This case followed by its parents up to a root, nearest first; `nil`
    /// when the parent chain loops (a self-parent or a longer cycle).
    ///
    /// Bounded by the number of cases, so it terminates on any input. It never
    /// traps: ``node`` traps on `nil`, the ratchet reports it.
    public var ancestry: [Self]? {
        var chain: [Self] = [self]
        var seen: Set<String> = [rawValue]
        var current = self
        while let next = current.parent {
            guard seen.insert(next.rawValue).inserted else { return nil }
            chain.append(next)
            current = next
        }
        return chain
    }

    /// Cycle detection lives HERE, not only in the ratchet: it is a bounded walk
    /// of at most `allCases.count` parents, and a cycle in production would
    /// otherwise recurse until the stack dies, with no message.
    public var node: VirtualNode {
        guard let chain = ancestry else {
            preconditionFailure("\(Self.self).\(self): the parent chain loops (a case is its own ancestor)")
        }
        return chain.reversed().reduce(Self.mount) { $0.child(PathSegment(stringLiteral: $1.rawValue)) }
    }
}
