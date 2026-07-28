//
//  Reconciler.swift
//  CoreKit
//
//  A generic, domain-blind, pure three-way reconcile. Value-in / value-out:
//  no I/O, no clocks, no async. Same inputs → byte-identical report (stable
//  sort by id). Classification never auto-resolves; policy is a separate step.
//

import Foundation

/// Generic three-way reconcile over `Identifiable` elements.
///
/// > ⚠️ **Preview / speculative surface** (shield D-1, 2026-07-28). As of this
/// > commit there is **no verified consumer** — the four originally-cited
/// > callers (`CacheRepository`, `SpecRebaser`, `SpecSyncEngine`, `kagami scopes
/// > lint`) were confirmed NOT to perform three-way merges. This namespace is
/// > extracted pre-emptively; its shape is unproven until a real consumer
/// > (e.g. `FlowDeliverySteward` salvage / `kagami lint --diff`) migrates onto
/// > it. Treat the public API as unstable until then — release should tag a
/// > `-preview` version rather than a stable minor.
///
/// - `Element`: the domain type; identity comes from `Element.ID`.
/// - `Key`: the change-detection token type returned by `contentKey`
///   (a version string, content hash, or `\.self` for value types).
///
/// Determinism requires `Element.ID: Comparable` (String / Int / etc.); UUID-keyed
/// callers project their id to a comparable form. This is a second generic parameter
/// — deliberately NOT `contentKey: (Element) -> some Hashable`, which is invalid Swift.
public struct Reconciler<Element: Identifiable & Sendable, Key: Hashable>: Sendable
where Element.ID: Comparable & Sendable {

    /// Extracts the change-detection token. Two elements with equal `contentKey` are
    /// considered unchanged relative to each other; unequal means modified.
    public let contentKey: @Sendable (Element) -> Key

    public init(contentKey: @escaping @Sendable (Element) -> Key) {
        self.contentKey = contentKey
    }

    // MARK: - Classification (pure)

    /// Classify every id across `base` / `mine` / `theirs`. Two-way diff is the
    /// degenerate call `reconcile(base: [], mine:, theirs:)`. Outcomes are stable-
    /// sorted by id, so a shuffled input yields a byte-identical result.
    ///
    /// - Precondition: each of `base` / `mine` / `theirs` is **unique by id**.
    ///   Inputs are treated as sets; a duplicate id is dropped first-writer-wins
    ///   (the second entry is silently discarded). DEBUG builds `assert` on
    ///   duplicates so tests catch them (shield S-1, 2026-07-28).
    public func reconcile(base: [Element], mine: [Element], theirs: [Element]) -> [ReconcileOutcome<Element.ID>] {
        let idx = index(base: base, mine: mine, theirs: theirs)
        return idx.ids.map { id in
            classify(id: id, base: idx.base[id], mine: idx.mine[id], theirs: idx.theirs[id])
        }
    }

    // MARK: - Resolution (classification + explicit policy)

    /// Classify, then apply `policy` to conflicts only. Non-conflict outcomes are
    /// never touched by policy. Returns the persistable `report`, the `merged`
    /// collection (stable-sorted by id), and the typed `refused` conflicts
    /// (non-empty only under `.refuseOnConflict`).
    ///
    /// - Precondition: `base` / `mine` / `theirs` are each unique-by-id (see
    ///   `reconcile(base:mine:theirs:)`).
    /// - Note: `merged` is NOT `decisions ⋈ merged`-joinable — a `preferMine`
    ///   decision where *mine removed* the element yields a
    ///   `decisions` entry (`.mine`) with **no** row in `merged`. Do not assume
    ///   every non-refused decision has a `merged` counterpart (shield S-2,
    ///   2026-07-28).
    public func resolve(
        base: [Element],
        mine: [Element],
        theirs: [Element],
        policy: ReconcilePolicy<Element> = .refuseOnConflict
    ) -> ReconcileResolution<Element> {
        let idx = index(base: base, mine: mine, theirs: theirs)
        var outcomes: [ReconcileOutcome<Element.ID>] = []
        outcomes.reserveCapacity(idx.ids.count)
        var decisions: [ResolvedDecision<Element.ID>] = []
        var merged: [Element] = []
        var refused: [Conflict<Element>] = []
        var counts = ReconcileCounts()

        for id in idx.ids {
            let b = idx.base[id]
            let m = idx.mine[id]
            let t = idx.theirs[id]
            let outcome = classify(id: id, base: b, mine: m, theirs: t)
            outcomes.append(outcome)
            tally(&counts, outcome)

            if outcome.isConflict {
                let conflict = Conflict(id: id, outcome: outcome, base: b, mine: m, theirs: t)
                let (kind, element) = resolveConflict(conflict: conflict, mine: m, theirs: t, policy: policy)
                decisions.append(ResolvedDecision(id: id, kind: kind))
                if kind == .refused { refused.append(conflict) }
                if let element { merged.append(element) }
            } else if let element = keptElement(for: outcome, mine: m, theirs: t) {
                merged.append(element)
            }
        }

        let report = ReconcileReport(outcomes: outcomes, decisions: decisions, counts: counts)
        return ReconcileResolution(report: report, merged: merged, refused: refused)
    }

    // MARK: - Private

    private struct Index {
        let ids: [Element.ID]
        let base: [Element.ID: Element]
        let mine: [Element.ID: Element]
        let theirs: [Element.ID: Element]
    }

    private func index(base: [Element], mine: [Element], theirs: [Element]) -> Index {
        let b = dict(base)
        let m = dict(mine)
        let t = dict(theirs)
        var set = Set<Element.ID>()
        set.formUnion(b.keys)
        set.formUnion(m.keys)
        set.formUnion(t.keys)
        return Index(ids: set.sorted(), base: b, mine: m, theirs: t)
    }

    private func dict(_ arr: [Element]) -> [Element.ID: Element] {
        // Precondition: inputs are unique-by-id (see reconcile/resolve docs).
        // Fail-loud in DEBUG so a duplicate-id caller is caught in tests instead
        // of silently losing rows (shield S-1, 2026-07-28); release keeps the
        // first-writer-wins fallback rather than trapping in production.
        assert(
            Set(arr.map(\.id)).count == arr.count,
            "Reconciler inputs must be unique-by-id; duplicate ids are silently dropped (first-writer-wins)."
        )
        return Dictionary(arr.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The total, orthogonal three-way classification. Every `(inBase, inMine, inTheirs)`
    /// combination maps to exactly one outcome.
    private func classify(id: Element.ID, base: Element?, mine: Element?, theirs: Element?) -> ReconcileOutcome<Element.ID> {
        let kb = base.map(contentKey)
        let km = mine.map(contentKey)
        let kt = theirs.map(contentKey)

        switch (base != nil, mine != nil, theirs != nil) {
        case (false, false, false):
            // Unreachable — id is drawn from the union of the three inputs. Present
            // for switch totality only.
            return .unchanged(id)
        case (false, true, false):
            return .addedMine(id)
        case (false, false, true):
            return .addedTheirs(id)
        case (false, true, true):
            return .bothAdded(id, km == kt ? .same : .different)
        case (true, false, false):
            return .removedByBoth(id)
        case (true, true, false):
            return km == kb ? .removedTheirs(id) : .modifyRemoveConflict(id, modifiedSide: .mine)
        case (true, false, true):
            return kt == kb ? .removedMine(id) : .modifyRemoveConflict(id, modifiedSide: .theirs)
        case (true, true, true):
            if km == kb && kt == kb { return .unchanged(id) }
            if km == kb { return .modifiedTheirs(id) }
            if kt == kb { return .modifiedMine(id) }
            return .bothModified(id, km == kt ? .same : .different)
        }
    }

    /// The surviving element for a NON-conflict outcome (or `nil` for a removal).
    private func keptElement(for outcome: ReconcileOutcome<Element.ID>, mine: Element?, theirs: Element?) -> Element? {
        switch outcome {
        case .unchanged, .addedMine, .modifiedMine:
            return mine
        case .addedTheirs, .modifiedTheirs:
            return theirs
        case .bothAdded(_, .same), .bothModified(_, .same):
            return mine // identical to theirs by contentKey
        case .removedMine, .removedTheirs, .removedByBoth:
            return nil
        case .bothAdded(_, .different), .bothModified(_, .different), .modifyRemoveConflict:
            return nil // conflicts are resolved via policy, not here
        }
    }

    /// Apply policy to one conflict → (recorded decision, surviving element or nil).
    private func resolveConflict(
        conflict: Conflict<Element>,
        mine: Element?,
        theirs: Element?,
        policy: ReconcilePolicy<Element>
    ) -> (DecisionKind, Element?) {
        switch policy {
        case .refuseOnConflict:
            return (.refused, nil)
        case .preferMine:
            return (.mine, mine) // nil when mine's action was removal → excluded
        case .preferTheirs:
            return (.theirs, theirs)
        case .custom(let decide):
            switch decide(conflict) {
            case .pickMine: return (.mine, mine)
            case .pickTheirs: return (.theirs, theirs)
            case .synthesize(let element): return (.synthesized, element)
            }
        }
    }

    private func tally(_ counts: inout ReconcileCounts, _ outcome: ReconcileOutcome<Element.ID>) {
        switch outcome {
        case .unchanged:
            counts.unchanged += 1
        case .addedMine, .addedTheirs:
            counts.added += 1
        case .removedMine, .removedTheirs, .removedByBoth:
            counts.removed += 1
        case .modifiedMine, .modifiedTheirs:
            counts.modified += 1
        case .bothAdded(_, .same), .bothModified(_, .same):
            counts.converged += 1
        case .bothAdded(_, .different), .bothModified(_, .different), .modifyRemoveConflict:
            counts.conflicts += 1
        }
    }
}
