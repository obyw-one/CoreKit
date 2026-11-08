import Foundation

// MARK: - DrainClock

/// Time seam for `DrainLoop`. Injected so every tick/backoff path is
/// deterministic under test — wall-clock in a drain loop is the exact
/// primitive class that flakes under kagami (shield finding 1f2d74f7,
/// 2026-08-07). Foundation-only, same discipline as `RepositoryProtocol`.
public protocol DrainClock: Sendable {
    /// Current instant. Async so a deterministic test clock can be an actor;
    /// `LiveDrainClock` keeps a synchronous `now()`, which satisfies this.
    func now() async -> Date

    /// Suspend for `seconds`. Throws `CancellationError` when the
    /// surrounding task is cancelled — `DrainLoop.run()` treats that as
    /// a stop signal, never an error.
    func sleep(for seconds: TimeInterval) async throws
}

// MARK: - LiveDrainClock

/// Production clock: real time, real sleeping.
public struct LiveDrainClock: DrainClock {
    public init() {}

    public func now() -> Date {
        Date()
    }

    public func sleep(for seconds: TimeInterval) async throws {
        try await TaskDeadline.sleep(TaskDeadline.duration(seconds: seconds))
    }
}

// MARK: - FakeDrainClock

/// Deterministic test clock: virtual time advances by exactly the slept
/// amount, and every sleep request is recorded so tests can assert the
/// backoff curve as data (`sleeps == [1, 2, 4, 8]`) instead of racing
/// timers. An actor: its virtual time and the recorded sleeps are shared
/// state, and the compiler proves them safe without a lock.
public actor FakeDrainClock: DrainClock {
    private var virtualNow: Date
    private var recorded: [TimeInterval] = []

    /// When set, the clock throws `CancellationError` after this many
    /// sleeps — the test's way of ending an otherwise infinite `run()`.
    private let cancelAfterSleeps: Int?

    public init(start: Date = Date(timeIntervalSince1970: 0), cancelAfterSleeps: Int? = nil) {
        self.virtualNow = start
        self.cancelAfterSleeps = cancelAfterSleeps
    }

    public func now() async -> Date {
        virtualNow
    }

    public func sleep(for seconds: TimeInterval) async throws {
        recorded.append(seconds)
        virtualNow = virtualNow.addingTimeInterval(seconds)
        if let limit = cancelAfterSleeps, recorded.count >= limit { throw CancellationError() }
    }

    /// Every sleep duration requested so far, in order.
    public var sleeps: [TimeInterval] {
        recorded
    }
}
