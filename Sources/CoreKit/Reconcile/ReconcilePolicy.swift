//
//  ReconcilePolicy.swift
//  CoreKit
//
//  Resolution policy — a SEPARATE, explicit step over the classified outcomes.
//  Classification never auto-resolves; policy is where a decision is made.
//

import Foundation

// MARK: - Conflict

/// A conflict surfaced by reconciliation, carrying the actual element values so a
/// `custom` policy can resolve it. `base` is `nil` for both-added conflicts (the
/// element did not exist in base); `mine`/`theirs` is `nil` for the removed side of
/// a modify/remove conflict.
public struct Conflict<Element: Identifiable & Sendable>: Sendable where Element.ID: Hashable & Sendable {
    public let id: Element.ID
    public let outcome: ReconcileOutcome<Element.ID>
    public let base: Element?
    public let mine: Element?
    public let theirs: Element?

    /// - Precondition: `id == outcome.id`. A `Conflict` whose `id` disagrees
    ///   with its `outcome`'s id is a contract violation — the two must name
    ///   the same element, or `custom` policy closures receive contradictory
    ///   information. Enforced via `precondition` (shield D-2, 2026-07-28).
    public init(id: Element.ID, outcome: ReconcileOutcome<Element.ID>, base: Element?, mine: Element?, theirs: Element?) {
        precondition(id == outcome.id, "Conflict.id (\(id)) must equal outcome.id (\(outcome.id))")
        self.id = id
        self.outcome = outcome
        self.base = base
        self.mine = mine
        self.theirs = theirs
    }
}

// MARK: - Decision

/// A `custom` policy's ruling on one conflict. `synthesize` is the caller's semantic
/// act — the Reconciler never invents a merged value itself.
public enum Decision<Element: Identifiable & Sendable>: Sendable {
    case pickMine
    case pickTheirs
    case synthesize(Element)
}

// MARK: - ReconcilePolicy

/// How conflicts are resolved. Non-conflict outcomes are never affected by policy.
///
/// - `refuseOnConflict` (the DEFAULT): resolve nothing; return the typed conflict set
///   as evidence. This is the operator-escalation / conflict-map path.
/// - `preferMine` / `preferTheirs`: take that side wholesale on every conflict.
/// - `custom`: caller decides per conflict. The closure MUST be pure — the Reconciler
///   cannot enforce it, and determinism of the resolved result depends on it.
public enum ReconcilePolicy<Element: Identifiable & Sendable>: Sendable where Element.ID: Sendable {
    case preferMine
    case preferTheirs
    case refuseOnConflict
    case custom(@Sendable (Conflict<Element>) -> Decision<Element>)

    /// The default policy: never auto-resolve a semantic conflict.
    public static var `default`: ReconcilePolicy {
        .refuseOnConflict
    }
}
