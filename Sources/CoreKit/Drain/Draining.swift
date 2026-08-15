import Foundation

// MARK: - Draining

/// The one drain seam — extracted 2026-08-07 after eleven bespoke drainers
/// grew in shikki alone (BacklogDrainer ×5 variants, ValidatedSpec ×2,
/// Memory ×2, KagamiHistory, BootDrainer), each re-implementing the same
/// scan → process → checkpoint loop with its own tick, backoff, and
/// corrupt-item story. Challenge 1f2d74f7 ratified the seam at the
/// FULL-DRAINER level (a DB/file client stays an injected dependency of the
/// conformer, never part of this surface).
///
/// SCOPE — deliberate exclusions (challenge verdict, accepted):
///   * JetStream/NATS-consumer drainers are NOT `Draining`. Their
///     idempotency is broker-owned (AckWait / MaxDeliver / redelivery);
///     forcing them under this roof would either waste those guarantees or
///     duplicate them app-side.
///   * One-shot migration passes are not drainers — no tick, no loop.
///
/// Conformers implement WHAT to drain; `DrainLoop` owns WHEN (tick,
/// backoff, quarantine, summaries). Keep conformers pure enough that a
/// single `tickOnce()` is fully deterministic under a `FakeDrainClock`.
public protocol Draining: Sendable {
    /// One unit of drainable work.
    associatedtype Item: Sendable

    /// Proof that an item finished; persisted by `checkpoint(_:for:)`.
    associatedtype Checkpoint: Sendable

    /// Stable identity for idempotency and quarantine keying.
    func itemID(_ item: Item) -> String

    /// Collect the currently drainable items. Called once per tick.
    /// Throwing here is an infrastructure failure — the loop backs off,
    /// it never crashes.
    func scan() async throws -> [Item]

    /// Do the work for one item. Throwing here quarantines THAT item
    /// (recorded, reported, skipped next ticks) — the loop continues with
    /// the remaining items. Silent drops are structurally impossible.
    func process(_ item: Item) async throws -> Checkpoint

    /// Persist the completion proof. Throwing here also quarantines the
    /// item: work-without-recorded-proof is the 0/0 trap of drain loops.
    func checkpoint(_ checkpoint: Checkpoint, for item: Item) async throws
}
