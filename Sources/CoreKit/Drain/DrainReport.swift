import Foundation

// MARK: - DrainTickSummary

/// What one tick did — emitted after every tick so operators see drain
/// health as data, not log archaeology.
public struct DrainTickSummary: Sendable, Codable, Equatable {
    /// Items returned by `scan()` this tick.
    public let scanned: Int
    /// Items processed AND checkpointed this tick.
    public let processed: Int
    /// Items that threw in `process`/`checkpoint` this tick.
    public let quarantined: Int
    /// Items skipped because they were already processed or already
    /// quarantined in this loop's lifetime.
    public let skipped: Int
    /// Tick start per the injected clock.
    public let startedAt: Date

    public init(scanned: Int, processed: Int, quarantined: Int, skipped: Int, startedAt: Date) {
        self.scanned = scanned
        self.processed = processed
        self.quarantined = quarantined
        self.skipped = skipped
        self.startedAt = startedAt
    }
}

// MARK: - DrainQuarantineRecord

/// A corrupt/failing item, preserved instead of silently dropped.
/// Consumers persist these (typed report row, @db, file) via the
/// `onQuarantine` hook — the loop itself stays storage-blind.
public struct DrainQuarantineRecord: Sendable, Codable, Equatable {
    public let itemID: String
    /// `String(describing:)` of the thrown error — enough for triage;
    /// typed errors belong to the conformer's own reporting.
    public let reason: String
    /// Which phase failed: "process" or "checkpoint".
    public let phase: String
    public let at: Date

    public init(itemID: String, reason: String, phase: String, at: Date) {
        self.itemID = itemID
        self.reason = reason
        self.phase = phase
        self.at = at
    }
}

// MARK: - DrainLoopConfig

/// Loop pacing. All values are DEFAULTS a call site may override — never
/// hardcode policy in a conformer (the shikki governor stays the
/// concurrency authority above this layer).
public struct DrainLoopConfig: Sendable, Equatable {
    /// Sleep between ticks that found work.
    public let tickInterval: TimeInterval
    /// First backoff sleep after an empty or failed scan.
    public let backoffBase: TimeInterval
    /// Multiplier per consecutive empty/failed tick.
    public let backoffMultiplier: Double
    /// Backoff ceiling.
    public let backoffMax: TimeInterval

    public init(
        tickInterval: TimeInterval = 5,
        backoffBase: TimeInterval = 1,
        backoffMultiplier: Double = 2,
        backoffMax: TimeInterval = 60
    ) {
        self.tickInterval = tickInterval
        self.backoffBase = backoffBase
        self.backoffMultiplier = backoffMultiplier
        self.backoffMax = backoffMax
    }
}
