import Foundation
import Testing
@testable import CoreKit

// MARK: - Fixtures

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0
    func tick() {
        lock.withLock { value += 1 }
    }

    /// Named `hits` (not `count`) so swiftlint's empty_count rule does not
    /// rewrite `hits == 0` into a non-existent `isEmpty` at auto-fix time.
    var hits: Int {
        lock.withLock { value }
    }
}

private struct Boom: Error, Equatable {}

// MARK: - Suite

@Suite("TaskDeadline primitive")
struct TaskDeadlineTests {
    @Test("T-01: body wins the throwing race — the value returns and the sleeper cancellation never escapes")
    func bodyWinsThrowingRace() async throws {
        let value = try await TaskDeadline.race(TaskDeadline.duration(seconds: 5)) {
            try await TaskDeadline.sleep(TaskDeadline.duration(seconds: 0.005))
            return 42
        }
        #expect(value == 42)
    }

    @Test("T-02: deadline wins the throwing race — TaskDeadlineError.timedOut is thrown and the body is cancelled")
    func deadlineWinsThrowingRace() async {
        let deadline = TaskDeadline.duration(seconds: 0.02)
        do {
            _ = try await TaskDeadline.race(deadline) {
                try await TaskDeadline.sleep(TaskDeadline.duration(seconds: 60))
                return "never"
            }
            Issue.record("expected TaskDeadlineError.timedOut")
        } catch let error as TaskDeadlineError {
            #expect(error == .timedOut(after: deadline))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("T-03: deadline wins the fallback race — the fallback returns and onTimeout ran exactly once")
    func deadlineWinsFallbackRace() async throws {
        let counter = CallCounter()
        let value = try await TaskDeadline.race(
            TaskDeadline.duration(seconds: 0.02),
            fallback: "fallback",
            onTimeout: { counter.tick() },
            body: {
                try await TaskDeadline.sleep(TaskDeadline.duration(seconds: 60))
                return "body"
            }
        )
        #expect(value == "fallback")
        #expect(counter.hits == 1)
    }

    @Test("body wins the fallback race — the body's value returns and onTimeout never runs")
    func bodyWinsFallbackRace() async throws {
        let counter = CallCounter()
        let value = try await TaskDeadline.race(
            TaskDeadline.duration(seconds: 5),
            fallback: "fallback",
            onTimeout: { counter.tick() },
            body: { "body" }
        )
        #expect(value == "body")
        #expect(counter.hits == 0)
    }

    @Test("a non-timeout error from body propagates unchanged through both race variants")
    func bodyErrorPropagates() async {
        do {
            _ = try await TaskDeadline.race(TaskDeadline.duration(seconds: 5)) {
                throw Boom()
            }
            Issue.record("expected Boom from throwing race")
        } catch is Boom {
            // expected
        } catch {
            Issue.record("unexpected error \(error) from throwing race")
        }

        do {
            _ = try await TaskDeadline.race(
                TaskDeadline.duration(seconds: 5),
                fallback: "fallback"
            ) {
                throw Boom()
            }
            Issue.record("expected Boom from fallback race")
        } catch is Boom {
            // expected
        } catch {
            Issue.record("unexpected error \(error) from fallback race")
        }
    }

    @Test("sleep(_:) honours cancellation with CancellationError instead of crashing the runtime")
    func sleepIsCancellable() async {
        let task = Task { try await TaskDeadline.sleep(TaskDeadline.duration(seconds: 60)) }
        task.cancel()
        do {
            try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
