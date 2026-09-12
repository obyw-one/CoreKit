import XCTest
@testable import CoreKit

// MARK: - Fixtures

private struct Row: Identifiable, Equatable, Sendable {
    let id: String
    let v: Int
}

private func row(_ id: String, _ v: Int) -> Row {
    Row(id: id, v: v)
}

/// Reconciler under test: identity from `id`, change-detection from `v`.
private let R = Reconciler<Row, Int>(contentKey: { $0.v })

/// Tiny deterministic PRNG so fuzz failures reproduce (no Foundation randomness).
private struct LCG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class ReconcilerTests: XCTestCase {
    // MARK: - Outcome corpus — every case constructible

    func testOutcomeCorpus() {
        func only(_ base: [Row], _ mine: [Row], _ theirs: [Row]) -> ReconcileOutcome<String> {
            let outs = R.reconcile(base: base, mine: mine, theirs: theirs)
            XCTAssertEqual(outs.count, 1)
            return outs[0]
        }
        XCTAssertEqual(only([row("a", 1)], [row("a", 1)], [row("a", 1)]), .unchanged("a"))
        XCTAssertEqual(only([], [row("a", 1)], []), .addedMine("a"))
        XCTAssertEqual(only([], [], [row("a", 1)]), .addedTheirs("a"))
        XCTAssertEqual(only([row("a", 1)], [], [row("a", 1)]), .removedMine("a"))
        XCTAssertEqual(only([row("a", 1)], [row("a", 1)], []), .removedTheirs("a"))
        XCTAssertEqual(only([row("a", 1)], [], []), .removedByBoth("a"))
        XCTAssertEqual(only([row("a", 1)], [row("a", 2)], [row("a", 1)]), .modifiedMine("a"))
        XCTAssertEqual(only([row("a", 1)], [row("a", 1)], [row("a", 2)]), .modifiedTheirs("a"))
        XCTAssertEqual(only([row("a", 1)], [row("a", 2)], [row("a", 2)]), .bothModified("a", .same))
        XCTAssertEqual(only([row("a", 1)], [row("a", 2)], [row("a", 3)]), .bothModified("a", .different))
        XCTAssertEqual(only([], [row("a", 2)], [row("a", 2)]), .bothAdded("a", .same))
        XCTAssertEqual(only([], [row("a", 2)], [row("a", 3)]), .bothAdded("a", .different))
        XCTAssertEqual(only([row("a", 1)], [row("a", 2)], []), .modifyRemoveConflict("a", modifiedSide: .mine))
        XCTAssertEqual(only([row("a", 1)], [], [row("a", 2)]), .modifyRemoveConflict("a", modifiedSide: .theirs))
    }

    func testIsConflictFlag() {
        XCTAssertFalse(ReconcileOutcome.bothModified("a", .same).isConflict)
        XCTAssertTrue(ReconcileOutcome.bothModified("a", .different).isConflict)
        XCTAssertFalse(ReconcileOutcome.bothAdded("a", .same).isConflict)
        XCTAssertTrue(ReconcileOutcome.bothAdded("a", .different).isConflict)
        XCTAssertTrue(ReconcileOutcome<String>.modifyRemoveConflict("a", modifiedSide: .theirs).isConflict)
        XCTAssertFalse(ReconcileOutcome<String>.unchanged("a").isConflict)
        XCTAssertFalse(ReconcileOutcome<String>.removedByBoth("a").isConflict)
    }

    // MARK: - Determinism: shuffled input → byte-identical report

    func testDeterminismUnderShuffle() {
        let base = (0..<40).map { row("id-\($0)", $0) }
        let mine = (0..<40).map { row("id-\($0)", $0 % 2 == 0 ? $0 : $0 + 100) }
        let theirs = (10..<50).map { row("id-\($0)", $0 % 3 == 0 ? $0 : $0 + 200) }

        var rng = LCG(seed: 42)
        let ref = R.resolve(base: base, mine: mine, theirs: theirs, policy: .preferMine)
        for _ in 0..<8 {
            let b = base.shuffled(using: &rng)
            let m = mine.shuffled(using: &rng)
            let t = theirs.shuffled(using: &rng)
            let got = R.resolve(base: b, mine: m, theirs: t, policy: .preferMine)
            XCTAssertEqual(got.report.outcomes, ref.report.outcomes, "outcomes must be shuffle-invariant")
            XCTAssertEqual(got.report.decisions, ref.report.decisions)
            XCTAssertEqual(got.report.counts, ref.report.counts)
            XCTAssertEqual(got.merged, ref.merged, "merged collection must be shuffle-invariant")
        }
        // Outcomes are sorted by id.
        let ids = ref.report.outcomes.map(\.id)
        XCTAssertEqual(ids, ids.sorted())
    }

    // MARK: - Degenerate two-way (base: [])

    func testTwoWayDegenerate() {
        let outs = R.reconcile(base: [], mine: [row("a", 1), row("b", 1)], theirs: [row("a", 1), row("c", 1)])
        // No base ⇒ everything is an add; shared id with equal content converges.
        XCTAssertEqual(outs, [.bothAdded("a", .same), .addedMine("b"), .addedTheirs("c")])
    }

    // MARK: - Policy matrix

    func testPolicyRefuseIsDefault() {
        let res = R.resolve(base: [row("a", 1)], mine: [row("a", 2)], theirs: [row("a", 3)])
        XCTAssertTrue(res.hasUnresolvedConflicts)
        XCTAssertEqual(res.refused.count, 1)
        XCTAssertEqual(res.report.refusedIDs, ["a"])
        XCTAssertEqual(res.merged, [], "refused conflict is not merged")
        XCTAssertEqual(res.report.decisions, [ResolvedDecision(id: "a", kind: .refused)])
    }

    func testPolicyPreferMineAndTheirs() {
        let mineWins = R.resolve(base: [row("a", 1)], mine: [row("a", 2)], theirs: [row("a", 3)], policy: .preferMine)
        XCTAssertEqual(mineWins.merged, [row("a", 2)])
        XCTAssertEqual(mineWins.report.decisions, [ResolvedDecision(id: "a", kind: .mine)])
        XCTAssertFalse(mineWins.hasUnresolvedConflicts)

        let theirsWins = R.resolve(base: [row("a", 1)], mine: [row("a", 2)], theirs: [row("a", 3)], policy: .preferTheirs)
        XCTAssertEqual(theirsWins.merged, [row("a", 3)])
        XCTAssertEqual(theirsWins.report.decisions, [ResolvedDecision(id: "a", kind: .theirs)])
    }

    func testPolicyPreferMineOnModifyRemoveExcludesWhenMineRemoved() {
        // theirs modified, mine removed → preferMine means "my side removed it" → excluded.
        let res = R.resolve(base: [row("a", 1)], mine: [], theirs: [row("a", 2)], policy: .preferMine)
        XCTAssertEqual(res.merged, [])
        XCTAssertEqual(res.report.decisions, [ResolvedDecision(id: "a", kind: .mine)])
    }

    func testPolicyCustomSynthesize() {
        let res = R.resolve(
            base: [row("a", 1)], mine: [row("a", 2)], theirs: [row("a", 3)],
            policy: .custom { conflict in
                // Merge by taking the max version — caller's semantic act.
                let mv = conflict.mine?.v ?? 0
                let tv = conflict.theirs?.v ?? 0
                return .synthesize(Row(id: conflict.id, v: max(mv, tv)))
            }
        )
        XCTAssertEqual(res.merged, [row("a", 3)])
        XCTAssertEqual(res.report.decisions, [ResolvedDecision(id: "a", kind: .synthesized)])
    }

    // MARK: - Counts

    func testCounts() {
        let res = R.resolve(
            base: [row("u", 1), row("mm", 1), row("mt", 1), row("rm", 1), row("rb", 1), row("conf", 1)],
            mine: [row("u", 1), row("mm", 2), row("mt", 1), row("rb", 1) /* rm removed */, row("conf", 2), row("am", 1)],
            theirs: [row("u", 1), row("mm", 1), row("mt", 2), row("rm", 1) /* rb removed by mine only? */, row("conf", 3), row("at", 1)]
        )
        // Careful tally: u=unchanged; mm=modifiedMine; mt=modifiedTheirs; rm=removedMine (mine dropped, theirs kept==base);
        // rb: base+mine present, theirs absent, mine==base ⇒ removedTheirs; conf=bothModified different; am=addedMine; at=addedTheirs.
        XCTAssertEqual(res.report.counts.unchanged, 1)
        XCTAssertEqual(res.report.counts.modified, 2) // mm + mt
        XCTAssertEqual(res.report.counts.removed, 2) // rm + rb(as removedTheirs)
        XCTAssertEqual(res.report.counts.added, 2) // am + at
        XCTAssertEqual(res.report.counts.conflicts, 1) // conf
        XCTAssertEqual(res.report.counts.total, res.report.outcomes.count)
    }

    // MARK: - Codable round-trip (evidence)

    func testReportCodableRoundTrip() throws {
        let res = R.resolve(
            base: [row("a", 1), row("b", 1)],
            mine: [row("a", 2), row("c", 1)],
            theirs: [row("a", 3), row("b", 1)],
            policy: .refuseOnConflict
        )
        let data = try JSONEncoder().encode(res.report)
        let decoded = try JSONDecoder().decode(ReconcileReport<String>.self, from: data)
        XCTAssertEqual(decoded, res.report)
        XCTAssertEqual(decoded.refusedIDs, ["a"])
    }

    // MARK: - Property/fuzz: partition totality

    func testPartitionTotalityFuzz() {
        var rng = LCG(seed: 1234)
        for _ in 0..<400 {
            let universe = (0..<12).map { "k\($0)" }
            func sample() -> [Row] {
                universe.compactMap { id in
                    Bool.random(using: &rng) ? row(id, Int.random(in: 0...3, using: &rng)) : nil
                }
            }
            let base = sample(), mine = sample(), theirs = sample()
            let outs = R.reconcile(base: base, mine: mine, theirs: theirs)

            // 1. Every id appears in exactly one outcome.
            let outIDs = outs.map(\.id)
            XCTAssertEqual(outIDs.count, Set(outIDs).count, "no id classified twice")

            // 2. The outcome id set == union of the three input id sets.
            let union = Set(base.map(\.id)).union(mine.map(\.id)).union(theirs.map(\.id))
            XCTAssertEqual(Set(outIDs), union, "every input id classified, none invented")

            // 3. Conflict ⇔ diverged both-change or modify/remove.
            for o in outs where o.isConflict {
                switch o {
                case .bothAdded(_, .different), .bothModified(_, .different), .modifyRemoveConflict:
                    break
                default:
                    XCTFail("isConflict true for a non-conflict shape: \(o)")
                }
            }
        }
    }
}
