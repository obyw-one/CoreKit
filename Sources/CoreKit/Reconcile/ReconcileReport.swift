//
//  ReconcileReport.swift
//  CoreKit
//
//  Persistable, deterministic evidence of a reconcile — Codable whenever the id is,
//  never requiring `Element: Codable`.
//

import Foundation

// MARK: - DecisionKind

/// How a single conflict was resolved, recorded id-only so the report stays Codable
/// without carrying element values.
public enum DecisionKind: Sendable, Equatable, Codable {
    case mine
    case theirs
    case synthesized
    /// `refuseOnConflict` left it unresolved for escalation.
    case refused
}

/// A per-id record of a conflict's resolution. Ordered (never a dictionary) so the
/// report is deterministic and diff-stable.
public struct ResolvedDecision<ID: Hashable & Sendable>: Sendable, Equatable {
    public let id: ID
    public let kind: DecisionKind

    public init(id: ID, kind: DecisionKind) {
        self.id = id
        self.kind = kind
    }
}

extension ResolvedDecision: Codable where ID: Codable {}

// MARK: - Counts

/// Aggregate tally of an outcome set — cheap summary for logs/ledgers.
public struct ReconcileCounts: Sendable, Equatable, Codable {
    public var unchanged: Int = 0
    public var added: Int = 0
    public var removed: Int = 0
    public var modified: Int = 0
    /// Converged both-add / both-modify (`.same`) — not conflicts.
    public var converged: Int = 0
    public var conflicts: Int = 0

    public init() {}

    public var total: Int { unchanged + added + removed + modified + converged + conflicts }
}

// MARK: - ReconcileReport

/// The deterministic, persistable outcome of a reconcile: the full classified
/// `outcomes` (sorted by id), the per-conflict `decisions`, and a `counts` summary.
///
/// `Codable` whenever `ID: Codable` — the Steward can persist a `refuseOnConflict`
/// report as escalation evidence verbatim, regardless of whether `Element` is Codable.
public struct ReconcileReport<ID: Hashable & Sendable>: Sendable, Equatable {
    /// Every id's classification, stable-sorted by id.
    public let outcomes: [ReconcileOutcome<ID>]
    /// One entry per conflict, stable-sorted by id.
    public let decisions: [ResolvedDecision<ID>]
    public let counts: ReconcileCounts

    public init(outcomes: [ReconcileOutcome<ID>], decisions: [ResolvedDecision<ID>], counts: ReconcileCounts) {
        self.outcomes = outcomes
        self.decisions = decisions
        self.counts = counts
    }

    /// The ids left unresolved under `refuseOnConflict` — the conflict map.
    public var refusedIDs: [ID] { decisions.filter { $0.kind == .refused }.map(\.id) }

    /// `true` when at least one conflict was refused (escalation needed).
    public var hasRefusedConflicts: Bool { decisions.contains { $0.kind == .refused } }
}

extension ReconcileReport: Codable where ID: Codable {}

// MARK: - ReconcileResolution

/// The result of `resolve`: the persistable `report`, the `merged` element collection
/// (stable-sorted by id, with resolved/kept elements only), and the typed `refused`
/// conflicts (non-empty only under `refuseOnConflict`).
public struct ReconcileResolution<Element: Identifiable & Sendable>: Sendable where Element.ID: Hashable & Sendable {
    public let report: ReconcileReport<Element.ID>
    public let merged: [Element]
    public let refused: [Conflict<Element>]

    public init(report: ReconcileReport<Element.ID>, merged: [Element], refused: [Conflict<Element>]) {
        self.report = report
        self.merged = merged
        self.refused = refused
    }

    public var hasUnresolvedConflicts: Bool { !refused.isEmpty }
}
