import CoreKitTestSupport
import Foundation
import Testing

/// T-04 in spec §4: the ratchet helper the fleet stands on, aimed
/// at CoreKit's own Sources dir. Empty result is the invariant — if
/// this fails, someone reintroduced `Task.sleep(for:tolerance:clock:)`
/// (the abort class of memory
/// [[task-sleep-for-cancelled-in-a-task-group-aborts-the-runtime-use-taskdeadline]]).
@Suite("CoreKit sleep-primitive ratchet")
struct CoreKitSleepRatchetTests {
    @Test("no clock-based Task.sleep(for:) remains anywhere under Sources/CoreKit")
    func noClockBasedSleepInCoreKitSources() {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Concurrency
            .deletingLastPathComponent() // CoreKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Sources/CoreKit", isDirectory: true)

        let hits = TaskDeadlineRatchet.clockBasedSleeps(in: sources)

        #expect(
            hits.isEmpty,
            "Clock-based Task.sleep(for:) reintroduced in Sources/CoreKit:\n\(hits.joined(separator: "\n"))"
        )
    }
}
