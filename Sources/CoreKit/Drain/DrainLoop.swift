import Foundation

// MARK: - DrainLoop

/// The one drain ENGINE: tick, backoff, in-run idempotency, quarantine.
/// Conformers of `Draining` say what to drain; this actor owns the loop
/// mechanics every bespoke drainer used to re-implement.
///
/// Guarantees:
///   * A throwing item never aborts the tick — it is quarantined
///     (recorded via `onQuarantine`) and skipped on later ticks.
///   * A throwing `scan()` never crashes the loop — it backs off.
///   * Every tick emits a `DrainTickSummary` via `onSummary` — a mute
///     drain loop is indistinguishable from a dead one, so muteness is
///     structurally impossible.
///   * All timing flows through the injected `DrainClock` — a
///     `FakeDrainClock` makes tick and backoff sequences pure data.
public actor DrainLoop<D: Draining> {
    private let drainer: D
    private let config: DrainLoopConfig
    private let clock: any DrainClock
    private let onSummary: @Sendable (DrainTickSummary) async -> Void
    private let onQuarantine: @Sendable (DrainQuarantineRecord) async -> Void

    /// Item ids processed in this loop's lifetime (in-run idempotency;
    /// durable idempotency is the conformer's checkpoint contract).
    private var seen: Set<String> = []
    /// Item ids quarantined in this loop's lifetime — never retried
    /// within the run; a restart (fresh loop) retries naturally.
    private var quarantined: Set<String> = []
    private var stopped = false
    private var consecutiveIdleTicks = 0

    public init(
        drainer: D,
        config: DrainLoopConfig = DrainLoopConfig(),
        clock: any DrainClock = LiveDrainClock(),
        onSummary: @escaping @Sendable (DrainTickSummary) async -> Void = { _ in },
        onQuarantine: @escaping @Sendable (DrainQuarantineRecord) async -> Void = { _ in }
    ) {
        self.drainer = drainer
        self.config = config
        self.clock = clock
        self.onSummary = onSummary
        self.onQuarantine = onQuarantine
    }

    // MARK: - Single tick (deterministic unit)

    /// One full scan-and-drain pass. Never throws: scan failure returns a
    /// zero-work summary (the run loop turns that into backoff).
    @discardableResult
    public func tickOnce() async -> DrainTickSummary {
        let startedAt = clock.now()

        let items: [D.Item]
        do {
            items = try await drainer.scan()
        } catch {
            let summary = DrainTickSummary(
                scanned: 0, processed: 0, quarantined: 0, skipped: 0, startedAt: startedAt
            )
            await onSummary(summary)
            return summary
        }

        var processed = 0
        var newlyQuarantined = 0
        var skipped = 0

        for item in items {
            let id = drainer.itemID(item)
            if seen.contains(id) || quarantined.contains(id) {
                skipped += 1
                continue
            }
            do {
                let proof = try await drainer.process(item)
                do {
                    try await drainer.checkpoint(proof, for: item)
                    seen.insert(id)
                    processed += 1
                } catch {
                    quarantined.insert(id)
                    newlyQuarantined += 1
                    await onQuarantine(
                        DrainQuarantineRecord(
                            itemID: id,
                            reason: String(describing: error),
                            phase: "checkpoint",
                            at: clock.now()
                        )
                    )
                }
            } catch {
                quarantined.insert(id)
                newlyQuarantined += 1
                await onQuarantine(
                    DrainQuarantineRecord(
                        itemID: id,
                        reason: String(describing: error),
                        phase: "process",
                        at: clock.now()
                    )
                )
            }
        }

        let summary = DrainTickSummary(
            scanned: items.count,
            processed: processed,
            quarantined: newlyQuarantined,
            skipped: skipped,
            startedAt: startedAt
        )
        await onSummary(summary)
        return summary
    }

    // MARK: - Run loop

    /// Tick forever with backoff on idle/failed ticks. Ends on `stop()`
    /// or task cancellation (surfaced as `CancellationError` from the
    /// clock's sleep) — both are clean exits, never errors.
    public func run() async {
        stopped = false
        while !stopped {
            let summary = await tickOnce()

            if summary.processed > 0 {
                consecutiveIdleTicks = 0
            } else {
                consecutiveIdleTicks += 1
            }

            let delay: TimeInterval
            if consecutiveIdleTicks == 0 {
                delay = config.tickInterval
            } else {
                let exponent = Double(consecutiveIdleTicks - 1)
                let raw = config.backoffBase * pow(config.backoffMultiplier, exponent)
                delay = min(raw, config.backoffMax)
            }

            do {
                try await clock.sleep(for: delay)
            } catch {
                break
            }
        }
    }

    public func stop() {
        stopped = true
    }

    // MARK: - Introspection (tests + doctor)

    public var processedIDs: Set<String> {
        seen
    }

    public var quarantinedIDs: Set<String> {
        quarantined
    }
}
