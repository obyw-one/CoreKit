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

/// A closed, named set of top-level nodes: the raw string IS the node name.
///
/// ```swift
/// enum Tree: String, VirtualNodeNaming {
///     case flows, state, queue
/// }
/// ```
///
/// A nested node (`state/ai-routing`) cannot be one raw value: that case
/// overrides ``node`` and inherits the default for the rest.
///
/// The default ``node`` converts the raw value with
/// `PathSegment(stringLiteral:)`, which TRAPS on an invalid name — a name
/// written in source is a programmer error, not runtime input, so the default
/// needs no `try`. Because the conformer is `CaseIterable`, walking
/// `allCases` (see `VirtualNodeNamingRatchet` in CoreKitTestSupport) fires
/// that trap in the suite instead of in a consumer.
public protocol VirtualNodeNaming: RawRepresentable, CaseIterable, VirtualNodeConvertible
where RawValue == String {}

extension VirtualNodeNaming {
    public var node: VirtualNode { VirtualNode(PathSegment(stringLiteral: rawValue)) }
}
