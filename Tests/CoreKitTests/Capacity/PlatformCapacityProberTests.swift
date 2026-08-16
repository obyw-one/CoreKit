import Foundation
@testable import CoreKit
import Testing

// MARK: - PlatformCapacityProberTests
//
// These are the only capacity tests that talk to real hardware, and even
// then only about invariants (a positive number, a monotone bound) — never
// specific values, so nothing here is machine-specific. Fixture-driven
// behaviour lives in `DeviceCapacitySnapshotTests`.

@Suite("PlatformCapacityProber")
struct PlatformCapacityProberTests {

    // MARK: - T-CP-04

    @Test("basis matches the compiled platform")
    func basisIsPlatformCorrect() {
        // The basis is a platform property, not a runtime tunable:
        // macOS is device-wide, iOS is per-process. Getting this wrong
        // would let a consumer read a per-process number against a
        // device-wide budget (basis-confusion silent-fail class).
        let snap = PlatformCapacityProber().probe()

        #if os(macOS)
        #expect(snap.basis == .deviceWide)
        #elseif os(iOS)
        #expect(snap.basis == .perProcess)
        // On iOS, `os_proc_available_memory` is bounded by the jetsam
        // limit — never equal to `ProcessInfo.physicalMemory` on any
        // real device. If they matched, a call site had substituted
        // the device total for the per-process ceiling (BR-CP-02).
        if let available = snap.availableNow {
            #expect(available != ProcessInfo.processInfo.physicalMemory)
        }
        #endif
    }

    // T-CP-06 lives in `DeviceCapacitySnapshotTests` — the ratchet is a
    // grep over the whole CoreKit source tree, not a probe test, and
    // keeping one copy prevents drift between two identical scanners.

    // MARK: - T-CP-07

    @Test("live macOS probe: totalRAM > 0 and availableNow <= totalRAM")
    func realProbeIsSane_macOS() throws {
        #if os(macOS)
        let snap = PlatformCapacityProber().probe()
        let total = try #require(snap.totalRAM, "hw.memsize must be readable on any macOS build target")
        #expect(total > 0)
        if let available = snap.availableNow {
            #expect(available <= total)
        }
        // If Metal advertised a working set limit, it cannot exceed
        // physical RAM — the recommended set is bounded by the physical
        // pool it draws from.
        if let gpu = snap.gpuWorkingSetLimit {
            #expect(gpu <= total)
        }
        #else
        // T-CP-07 is macOS-only per the spec; the iOS live probe cannot
        // assert `availableNow <= totalRAM` because `totalRAM` is `nil`
        // on iOS under BR-CP-05, and there is no positive invariant
        // worth asserting against a value that may legitimately be 0
        // under jetsam pressure.
        #endif
    }

}
