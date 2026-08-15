import Foundation

// MARK: - DrainClock

/// Time seam for `DrainLoop`. Injected so every tick/backoff path is
/// deterministic under test — wall-clock in a drain loop is the exact
/// primitive class that flakes under kagami (shield finding 1f2d74f7,
/// 2026-08-07). Foundation-only, same discipline as `RepositoryProtocol`.
public protocol DrainClock: Sendable {
    /// Current instant.
    func now() -> Date

    /// Suspend for `seconds`. Throws `CancellationError` when the
    /// surrounding task is cancelled — `DrainLoop.run()` treats that as
    /// a stop signal, never an error.
    func sleep(for seconds: TimeInterval) async throws
}

// MARK: - LiveDrainClock

/// Production clock: real time, real sleeping.
public struct LiveDrainClock: DrainClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

// MARK: - FakeDrainClock

/// Deterministic test clock: virtual time advances by exactly the slept
/// amount, and every sleep request is recorded so tests can assert the
/// backoff curve as data (`sleeps == [1, 2, 4, 8]`) instead of racing
/// timers. Lock-guarded final class so `now()` stays synchronous.
public final class FakeDrainClock: DrainClock, @unchecked Sendable {
    private let lock = NSLock()
    private var virtualNow: Date
    private var recorded: [TimeInterval] = []

    /// When set, the clock throws `CancellationError` after this many
    /// sleeps — the test's way of ending an otherwise infinite `run()`.
    private let cancelAfterSleeps: Int?

    public init(start: Date = Date(timeIntervalSince1970: 0), cancelAfterSleeps: Int? = nil) {
        self.virtualNow = start
        self.cancelAfterSleeps = cancelAfterSleeps
    }

    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return virtualNow
    }

    public func sleep(for seconds: TimeInterval) async throws {
        let shouldCancel: Bool = lock.withLock {
            recorded.append(seconds)
            virtualNow = virtualNow.addingTimeInterval(seconds)
            return cancelAfterSleeps.map { recorded.count >= $0 } ?? false
        }
        if shouldCancel { throw CancellationError() }
    }

    /// Every sleep duration requested so far, in order.
    public var sleeps: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
