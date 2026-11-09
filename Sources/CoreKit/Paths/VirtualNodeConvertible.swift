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
/// The raw string is the node's PATH, not one segment: a nested node is just
/// a raw value with the separator in it, and no case needs a body.
///
/// ```swift
/// enum Tree: String, VirtualNodeNaming {
///     case flows, state
///     case aiRouting = "state/ai-routing"
/// }
/// ```
///
/// The raw value is authored in source, so it is read with the POSIX wire
/// separator (`/`) whatever the host OS. The default ``node`` converts it
/// with `VirtualPath(stringLiteral:)`, which TRAPS on an invalid path — a
/// path written in source is a programmer error, not runtime input, so the
/// default needs no `try`. Because the conformer is `CaseIterable`, walking
/// `allCases` (see `VirtualNodeNamingRatchet` in CoreKitTestSupport) fires
/// that trap in the suite instead of in a consumer.
public protocol VirtualNodeNaming: RawRepresentable, CaseIterable, VirtualNodeConvertible
where RawValue == String {}

extension VirtualNodeNaming {
    public var node: VirtualNode { VirtualNode(path: VirtualPath(stringLiteral: rawValue)) }
}
