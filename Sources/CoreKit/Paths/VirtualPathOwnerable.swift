//
//  VirtualPathOwnerable.swift
//  CoreKit
//

import Foundation

// MARK: - VirtualPathRegistry

/// The set of owner KINDS added to the tree (BR-RP-02).
///
/// An immutable value, built once at the composition root and handed to the
/// resolver — never a mutable global that any import can append to. Adding an
/// owner returns a new registry, so "who is in the tree" is a fact of how the
/// layer was composed and a test can assert it.
///
/// Two things are enforced at the moment an owner is added, because they are
/// the two ways a tree silently drifts:
///
/// - **No clash.** Two different kinds claiming one ``VirtualPlacement`` would
///   write to the same place under different models — the drift that sets in
///   when a resource names its path in one place and a second vocabulary
///   redefines it. Adding the SAME kind twice is idempotent (an assembly
///   listed twice is a no-op, not a corruption).
/// - **Enumerability.** ``entries`` is the list a doctor check or a cleanup sweep
///   reads to know what the tree contains, instead of grepping for
///   string literals.
public struct VirtualPathRegistry: Sendable, Equatable {

    /// One registered owner kind.
    public struct Entry: Sendable, Equatable {
        /// The kind's static placement.
        public let placement: VirtualPlacement
        /// The kind's fully qualified type name, for reports and clash messages.
        public let ownerTypeName: String
        fileprivate let identity: ObjectIdentifier
    }

    /// Every registered kind, in registration order.
    public private(set) var entries: [Entry]

    /// The registry with no owners.
    public static let empty = VirtualPathRegistry(entries: [])

    private init(entries: [Entry]) {
        self.entries = entries
    }

    /// A registry holding `owners`; throws on the first clash.
    public init(_ owners: [any VirtualPathOwning.Type]) throws(VirtualPathError) {
        self = .empty
        for owner in owners {
            self = try adding(owner)
        }
    }

    // MARK: - Registration

    /// This registry plus `owner`'s kind. Idempotent for a kind already in;
    /// throws ``VirtualPathError/placementClash(placement:existing:incoming:)``
    /// when a DIFFERENT kind already owns the placement.
    public func adding(_ owner: any VirtualPathOwning.Type) throws(VirtualPathError) -> VirtualPathRegistry {
        let identity = ObjectIdentifier(owner)
        let placement = owner.placement
        if entries.contains(where: { $0.identity == identity }) { return self }
        if let existing = entries.first(where: { $0.placement == placement }) {
            throw .placementClash(
                placement: placement.description,
                existing: existing.ownerTypeName,
                incoming: String(reflecting: owner))
        }
        let entry = Entry(placement: placement, ownerTypeName: String(reflecting: owner), identity: identity)
        return VirtualPathRegistry(entries: entries + [entry])
    }

    // MARK: - Queries

    /// `true` when `owner`'s kind was added to the tree.
    public func contains(_ owner: any VirtualPathOwning.Type) -> Bool {
        let identity = ObjectIdentifier(owner)
        return entries.contains { $0.identity == identity }
    }

    /// The registered kinds located directly on `node`.
    public func entries(on node: VirtualNode) -> [Entry] {
        entries.filter { $0.placement.node == node }
    }
}

// MARK: - VirtualPathOwnerable

/// What a ``PathResolving`` holds: the registry of owners added to the tree.
///
/// Split out as its own protocol (BR-RP-02) so a component that only needs to
/// ENUMERATE the tree — a doctor check, a sweep — can ask for exactly that,
/// and so a resolver that serves a different medium (an object-store
/// resolver) holds the same registry the local one does.
public protocol VirtualPathOwnerable: Sendable {
    /// The owner kinds added to this tree.
    var registry: VirtualPathRegistry { get }
}
