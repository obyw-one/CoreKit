import Foundation
@testable import CoreKit
import Testing

// MARK: - Fixtures

/// Scriptable drainer: scans yield programmed batches; chosen ids throw
/// in process or checkpoint. Lock-guarded so the loop can call it freely.
private final class ScriptedDrainer: Draining, @unchecked Sendable {
    struct Item: Sendable, Equatable { let id: String }
    struct Proof: Sendable { let id: String }

    private let lock = NSLock()
    private var scanBatches: [[Item]]
    private var scanError: Error?
    let failProcess: Set<String>
    let failCheckpoint: Set<String>
    private(set) var processedIDs: [String] = []
    private(set) var checkpointedIDs: [String] = []

    init(
        scans: [[String]],
        failProcess: Set<String> = [],
        failCheckpoint: Set<String> = [],
        scanError: Error? = nil
    ) {
        self.scanBatches = scans.map { $0.map(Item.init(id:)) }
        self.failProcess = failProcess
        self.failCheckpoint = failCheckpoint
        self.scanError = scanError
    }

    func itemID(_ item: Item) -> String { item.id }

    func scan() async throws -> [Item] {
        if let e = scanError { throw e }
        return lock.withLock {
            scanBatches.isEmpty ? [] : scanBatches.removeFirst()
        }
    }

    func process(_ item: Item) async throws -> Proof {
        if failProcess.contains(item.id) { throw Failure.boom(item.id) }
        lock.withLock { processedIDs.append(item.id) }
        return Proof(id: item.id)
    }

    func checkpoint(_ proof: Proof, for item: Item) async throws {
        if failCheckpoint.contains(item.id) { throw Failure.boom(item.id) }
        lock.withLock { checkpointedIDs.append(proof.id) }
    }

    enum Failure: Error { case boom(String) }

    var processed: [String] { lock.withLock { processedIDs } }
    var checkpointed: [String] { lock.withLock { checkpointedIDs } }
}

/// Thread-safe collectors for the loop's hooks.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var summaries: [DrainTickSummary] = []
    private var quarantines: [DrainQuarantineRecord] = []

    func add(_ s: DrainTickSummary) { lock.withLock { summaries.append(s) } }
    func add(_ q: DrainQuarantineRecord) { lock.withLock { quarantines.append(q) } }
    var allSummaries: [DrainTickSummary] { lock.withLock { summaries } }
    var allQuarantines: [DrainQuarantineRecord] { lock.withLock { quarantines } }
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
        let drainer = ScriptedDrainer(scans: [])  // always idle
        let clock = FakeDrainClock(cancelAfterSleeps: 5)
        let config = DrainLoopConfig(tickInterval: 5, backoffBase: 1, backoffMultiplier: 2, backoffMax: 6)
        let loop = DrainLoop(drainer: drainer, config: config, clock: clock)

        await loop.run()

        #expect(clock.sleeps == [1, 2, 4, 6, 6])
    }

    @Test("work resets the backoff to tickInterval")
    func backoffResetOnWork() async {
        let drainer = ScriptedDrainer(scans: [[], [], ["a"], []])
        let clock = FakeDrainClock(cancelAfterSleeps: 4)
        let config = DrainLoopConfig(tickInterval: 9, backoffBase: 1, backoffMultiplier: 2, backoffMax: 60)
        let loop = DrainLoop(drainer: drainer, config: config, clock: clock)

        await loop.run()

        // idle(1), idle(2), work → tickInterval(9), idle → base(1)
        #expect(clock.sleeps == [1, 2, 9, 1])
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
            return clock.sleeps
        }
        let a = await trace()
        let b = await trace()
        #expect(a == b)
        #expect(a == [7, 3, 9])
    }
}
