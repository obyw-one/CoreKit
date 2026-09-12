import Foundation

// MARK: - TaskDeadlineError

/// The error thrown by the throwing variant of `TaskDeadline.race`
/// when the deadline fires before `body` finishes.
public enum TaskDeadlineError: Error, Equatable, Sendable {
    case timedOut(after: Duration)
}

// MARK: - TaskDeadline

/// The fleet's one deadline and sleep primitive.
///
/// `Task.sleep(for:tolerance:clock:)` aborts the Swift 6 runtime
/// (`swift_task_dealloc: freed pointer was not the last allocation`)
/// when the sleeper is cancelled from inside a task group under
/// load; the safe shape is `Task.sleep(nanoseconds:)`. Every kit in
/// the fleet stands on this primitive so no consumer has to
/// re-discover that rule — the accompanying `CoreKitTestSupport`
/// ratchet asserts the shape stays gone.
public enum TaskDeadline {
    /// Race `body` against a `duration`. Returns the body's value if
    /// it finishes first; throws `TaskDeadlineError.timedOut` if the
    /// deadline fires first; re-throws any error the body raises.
    ///
    /// Whichever side loses is cancelled — the sleeper's cancellation
    /// is swallowed inside so it can never propagate as a spurious
    /// error from the group.
    public static func race<T: Sendable>(
        _ duration: Duration,
        body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: RaceOutcome<T>.self) { group in
            group.addTask {
                let value = try await body()
                return .body(value)
            }
            group.addTask {
                // `try?` swallows the CancellationError the sleeper
                // raises when the body wins — that error must never
                // surface as the race's result.
                try? await Self.sleep(duration)
                return .deadline
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw TaskDeadlineError.timedOut(after: duration)
            }
            switch first {
            case let .body(value):
                return value
            case .deadline:
                throw TaskDeadlineError.timedOut(after: duration)
            }
        }
    }

    /// Race `body` against a `duration`, falling back to `fallback`
    /// when the deadline fires first. `onTimeout` runs exactly once
    /// on the timeout path and never on the happy path. Errors from
    /// `body` that are not `TaskDeadlineError` propagate unchanged.
    public static func race<T: Sendable>(
        _ duration: Duration,
        fallback: T,
        onTimeout: (@Sendable () -> Void)? = nil,
        body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await race(duration, body: body)
        } catch is TaskDeadlineError {
            onTimeout?()
            return fallback
        }
    }

    /// Suspend the current task for `duration`. Uses
    /// `Task.sleep(nanoseconds:)` — the shape that does not abort
    /// the Swift 6 runtime under cancellation in a task group.
    /// Throws `CancellationError` when the surrounding task is
    /// cancelled; every consumer treats that as a stop signal.
    public static func sleep(_ duration: Duration) async throws {
        try await Task.sleep(nanoseconds: nanoseconds(from: duration))
    }

    /// Convenience: build a `Duration` from a `TimeInterval` so
    /// consumers that already speak seconds do not have to reach
    /// into the `Duration` builder themselves.
    public static func duration(seconds: TimeInterval) -> Duration {
        .seconds(max(0, seconds))
    }

    // MARK: - Internals

    private enum RaceOutcome<T: Sendable>: Sendable {
        case body(T)
        case deadline
    }

    private static func nanoseconds(from duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        let clampedSeconds = max(Int64(0), seconds)
        let secondsInNanos = UInt64(clampedSeconds).multipliedReportingOverflow(by: 1_000_000_000)
        let secondsPart = secondsInNanos.overflow ? UInt64.max : secondsInNanos.partialValue
        // 1 attosecond = 1e-18 s, 1 nanosecond = 1e-9 s → attos/1e9 = nanos.
        let attoNanos = UInt64(max(Int64(0), attoseconds)) / 1_000_000_000
        let total = secondsPart.addingReportingOverflow(attoNanos)
        return total.overflow ? UInt64.max : total.partialValue
    }
}
