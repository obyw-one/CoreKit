//
//  ReconcileOutcome.swift
//  CoreKit
//
//  The typed, exhaustive classification of a three-way reconcile.
//

import Foundation

// MARK: - Convergence

/// Whether two independently-changed sides converged to the same content or diverged.
///
/// `.same` is NOT a conflict — both sides happened to reach the same value, so any
/// policy accepts it. `.different` is a genuine conflict requiring resolution.
public enum Convergence: Sendable, Equatable, Codable {
    case same
    case different
}

// MARK: - Side

/// In a modify/remove conflict, names the side that **modified** the element.
/// The other side removed it. Defined explicitly so two implementations can never
/// disagree on which side the associated value refers to.
public enum Side: Sendable, Equatable, Codable {
    case mine
    case theirs
}

// MARK: - ReconcileOutcome

/// The classification of a single element `id` across a three-way reconcile.
///
/// Exhaustive over every reachable `(inBase, inMine, inTheirs)` state — a consumer
/// switching over this enum cannot silently drop a legal input. Carries only the
/// `ID` (never the `Element`), so the outcome — and any report built from it — is
/// `Codable` whenever `ID` is, without requiring `Element: Codable`.
public enum ReconcileOutcome<ID: Hashable & Sendable>: Sendable, Equatable {
    /// Present and identical in base, mine, theirs.
    case unchanged(ID)
    /// Absent from base and theirs; added only by mine.
    case addedMine(ID)
    /// Absent from base and mine; added only by theirs.
    case addedTheirs(ID)
    /// In base and theirs unchanged; removed by mine.
    case removedMine(ID)
    /// In base and mine unchanged; removed by theirs.
    case removedTheirs(ID)
    /// In base; removed by BOTH sides — converged deletion, non-conflicting.
    case removedByBoth(ID)
    /// In base and theirs unchanged; modified by mine.
    case modifiedMine(ID)
    /// In base and mine unchanged; modified by theirs.
    case modifiedTheirs(ID)
    /// Absent from base; added by both. `.same` = converged (no conflict); `.different` = conflict.
    case bothAdded(ID, Convergence)
    /// In base; modified by both. `.same` = converged (no conflict); `.different` = conflict.
    case bothModified(ID, Convergence)
    /// One side modified, the other removed. `modifiedSide` names the side that modified.
    case modifyRemoveConflict(ID, modifiedSide: Side)

    /// The element id this outcome classifies.
    public var id: ID {
        switch self {
        case let .unchanged(id), let .addedMine(id), let .addedTheirs(id),
             let .removedMine(id), let .removedTheirs(id), let .removedByBoth(id),
             let .modifiedMine(id), let .modifiedTheirs(id):
            return id
        case let .bothAdded(id, _), let .bothModified(id, _):
            return id
        case let .modifyRemoveConflict(id, _):
            return id
        }
    }

    /// `true` only for outcomes that require policy resolution: diverged both-adds /
    /// both-modifies and every modify/remove. Converged (`.same`) outcomes are not conflicts.
    public var isConflict: Bool {
        switch self {
        case let .bothAdded(_, c), let .bothModified(_, c):
            return c == .different
        case .modifyRemoveConflict:
            return true
        default:
            return false
        }
    }
}

// Codable evidence: available whenever the id is Codable — never requires `Element: Codable`.
extension ReconcileOutcome: Codable where ID: Codable {}
