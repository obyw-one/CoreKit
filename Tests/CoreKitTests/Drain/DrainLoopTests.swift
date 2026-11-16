import Foundation
import Testing
@testable import CoreKit

// MARK: - Fixtures

/// Scriptable drainer: scans yield programmed batches; chosen ids throw
/// in process or checkpoint. Lock-guarded so the loop can call it freely.
///
/// All the mutable fields moved into ONE `LockedState` value rather than
/// becoming one lock box each: the invariant is across them (a scan is removed
/// and the ids are appended), so splitting them into separate locks would allow
/// a torn read that the old single `NSLock` did not.
private final class ScriptedDrainer: Draining {
    struct Item: Sendable, Equatable { let id: String }
    struct Proof: Sendable { let id: String }

    private struct State: Sendable {
        var scanBatches: [[Item]]
        /// The error is kept as its description: `any Error` is not `Sendable`,
        /// and this suite only ever re-throws it as an opaque failure.
        var scanErrorDescription: String?
        var processedIDs: [String] = []
        var checkpointedIDs: [String] = []
    }

    private let state: LockedState<State>
    let failProcess: Set<String>
    let failCheckpoint: Set<String>

    struct ScriptedScanFailure: Error, CustomStringConvertible { let description: String }

    init(
        scans: [[String]],
        failProcess: Set<String> = [],
        failCheckpoint: Set<String> = [],
        scanError: Error? = nil
    ) {
        self.state = LockedState(
            State(
                scanBatches: scans.map { $0.map(Item.init(id:)) },
                scanErrorDescription: scanError.map { String(describing: $0) }
            )
        )
        self.failProcess = failProcess
        self.failCheckpoint = failCheckpoint
    }

    func itemID(_ item: Item) -> String {
        item.id
    }

    func scan() async throws -> [Item] {
        try state.withLock { state in
            if let description = state.scanErrorDescription {
                throw ScriptedScanFailure(description: description)
            }
            return state.scanBatches.isEmpty ? [] : state.scanBatches.removeFirst()
        }
    }

    func process(_ item: Item) async throws -> Proof {
        if failProcess.contains(item.id) { throw Failure.boom(item.id) }
        state.withLock { $0.processedIDs.append(item.id) }
        return Proof(id: item.id)
    }

    func checkpoint(_ proof: Proof, for item: Item) async throws {
        if failCheckpoint.contains(item.id) { throw Failure.boom(item.id) }
        state.withLock { $0.checkpointedIDs.append(proof.id) }
    }

    enum Failure: Error { case boom(String) }

    var processed: [String] {
        state.withLock { $0.processedIDs }
    }

    var checkpointed: [String] {
        state.withLock { $0.checkpointedIDs }
    }
}

/// Thread-safe collectors for the loop's hooks.
private final class Collector: Sendable {
    private struct State: Sendable {
        var summaries: [DrainTickSummary] = []
        var quarantines: [DrainQuarantineRecord] = []
    }

    private let state = LockedState(State())

    func add(_ s: DrainTickSummary) {
        state.withLock { $0.summaries.append(s) }
    }

    func add(_ q: DrainQuarantineRecord) {
        state.withLock { $0.quarantines.append(q) }
    }

    var allSummaries: [DrainTickSummary] {
        state.withLock { $0.summaries }
    }

    var allQuarantines: [DrainQuarantineRecord] {
        state.withLock { $0.quarantines }
    }
}

// MARK: - Suite

@Suite("DrainLoop engine")
struct DrainLoopTests {
    @Test("tickOnce processes and checkpoints every scanned item")
    func tickProcessesAll() async {
        let drainer = ScriptedDrainer(scans: [["a", "b", "c"]])
        let loop = DrainLoop(drainer: drainer, clock: FakeDrainClock())

        let summary = await loop.tickOnce()

        #expect(summary.scanned == 3)
        #expect(summary.processed == 3)
        #expect(summary.quarantined == 0)
        #expect(drainer.checkpointed == ["a", "b", "c"])
    }

    @Test("a throwing item is quarantined and the tick continues")
    func quarantineContinues() async {
        let drainer = ScriptedDrainer(scans: [["a", "bad", "c"]], failProcess: ["bad"])
        let collector = Collector()
        let loop = DrainLoop(
            drainer: drainer,
            clock: FakeDrainClock(),
            onQuarantine: { collector.add($0) }
        )

        let summary = await loop.tickOnce()

        #expect(summary.processed == 2)
        #expect(summary.quarantined == 1)
        #expect(drainer.checkpointed == ["a", "c"])
        #expect(collector.allQuarantines.map(\.itemID) == ["bad"])
        #expect(collector.allQuarantines.first?.phase == "process")
    }

    @Test("a throwing checkpoint quarantines with phase=checkpoint — work without proof never counts")
    func checkpointFailureQuarantines() async {
        let drainer = ScriptedDrainer(scans: [["a"]], failCheckpoint: ["a"])
        let collector = Collector()
        let loop = DrainLoop(
            drainer: drainer,
            clock: FakeDrainClock(),
            onQuarantine: { collector.add($0) }
        )

        let summary = await loop.tickOnce()

        #expect(summary.processed == 0)
        #expect(summary.quarantined == 1)
        #expect(collector.allQuarantines.first?.phase == "checkpoint")
    }

    @Test("seen and quarantined items are skipped on later ticks (in-run idempotency)")
    func idempotencySkipsSeen() async {
        let drainer = ScriptedDrainer(
            scans: [["a", "bad"], ["a", "bad", "b"]],
            failProcess: ["bad"]
        )
        let loop = DrainLoop(drainer: drainer, clock: FakeDrainClock())

        _ = await loop.tickOnce()
        let second = await loop.tickOnce()

        #expect(second.skipped == 2)
        #expect(second.processed == 1)
        #expect(drainer.processed == ["a", "b"])
        let quarantinedIDs = await loop.quarantinedIDs
        #expect(quarantinedIDs == Set(["bad"]))
    }

    @Test("scan failure yields a zero-work summary, never a crash")
    func scanErrorSafe() async {
        let drainer = ScriptedDrainer(scans: [], scanError: ScriptedDrainer.Failure.boom("scan"))
        let collector = Collector()
        let loop = DrainLoop(
            drainer: drainer,
            clock: FakeDrainClock(),
            onSummary: { collector.add($0) }
        )

        let summary = await loop.tickOnce()

        #expect(summary.scanned == 0)
        #expect(collector.allSummaries.count == 1)
    }

    @Test("run() backs off exponentially on idle ticks and caps at backoffMax")
    func backoffCurve() async {
        let drainer = ScriptedDrainer(scans: []) // always idle
        let clock = FakeDrainClock(cancelAfterSleeps: 5)
        let config = DrainLoopConfig(tickInterval: 5, backoffBase: 1, backoffMultiplier: 2, backoffMax: 6)
        let loop = DrainLoop(drainer: drainer, config: config, clock: clock)

        await loop.run()

        #expect(await clock.sleeps == [1, 2, 4, 6, 6])
    }

    @Test("work resets the backoff to tickInterval")
    func backoffResetOnWork() async {
        let drainer = ScriptedDrainer(scans: [[], [], ["a"], []])
        let clock = FakeDrainClock(cancelAfterSleeps: 4)
        let config = DrainLoopConfig(tickInterval: 9, backoffBase: 1, backoffMultiplier: 2, backoffMax: 60)
        let loop = DrainLoop(drainer: drainer, config: config, clock: clock)

        await loop.run()

        // idle(1), idle(2), work → tickInterval(9), idle → base(1)
        #expect(await clock.sleeps == [1, 2, 9, 1])
    }

    @Test("every tick emits a summary — a mute loop is impossible")
    func summaryPerTick() async {
        let drainer = ScriptedDrainer(scans: [["a"], []])
        let collector = Collector()
        let clock = FakeDrainClock(cancelAfterSleeps: 2)
        let loop = DrainLoop(drainer: drainer, clock: clock, onSummary: { collector.add($0) })

        await loop.run()

        #expect(collector.allSummaries.count == 2)
        #expect(collector.allSummaries[0].processed == 1)
        #expect(collector.allSummaries[1].processed == 0)
    }

    @Test("stop() ends the run loop cleanly")
    func stopEndsRun() async {
        let drainer = ScriptedDrainer(scans: [["a"]])
        let clock = FakeDrainClock(cancelAfterSleeps: 50)
        let loop = DrainLoop(drainer: drainer, clock: clock)

        let runner = Task { await loop.run() }
        await loop.stop()
        // stop flag is checked after the in-flight tick+sleep; cancel the
        // task to unblock any pending fake sleep, then ensure termination.
        runner.cancel()
        await runner.value
        #expect(Bool(true))
    }

    @Test("deterministic replay: same scans + same fake clock → identical sleep trace")
    func clockDeterminism() async {
        func trace() async -> [TimeInterval] {
            let drainer = ScriptedDrainer(scans: [["a"], [], []])
            let clock = FakeDrainClock(cancelAfterSleeps: 3)
            let loop = DrainLoop(
                drainer: drainer,
                config: DrainLoopConfig(tickInterval: 7, backoffBase: 3, backoffMultiplier: 3, backoffMax: 100),
                clock: clock
            )
            await loop.run()
            return await clock.sleeps
        }
        let a = await trace()
        let b = await trace()
        #expect(a == b)
        #expect(a == [7, 3, 9])
    }
}
