import Foundation

// MARK: - MockCapacityProber

/// The test seam for `DeviceCapacityProbing` (BR-CP-04). Every test in the
/// fleet that asserts anything about capacity behaviour uses this — no
/// test in CoreKit or downstream ever probes real hardware except the
/// single `T-CP-07_realProbeIsSane` invariant, and even that uses no
/// fixture values.
///
/// Held as a reference type with a lock so a single test can walk a
/// prober through multiple pressure states (idle → loaded → thrashing)
/// without re-wiring the consumer. This is what `T-CP-03` uses to
/// demonstrate that `availableNow` moves while `totalRAM` does not.
public final class MockCapacityProber: DeviceCapacityProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot: DeviceCapacitySnapshot
    private var _probeCount: Int = 0

    public init(_ snapshot: DeviceCapacitySnapshot) {
        self._snapshot = snapshot
    }

    // MARK: - DeviceCapacityProbing

    public func probe() -> DeviceCapacitySnapshot {
        lock.withLock {
            _probeCount += 1
            return _snapshot
        }
    }

    // MARK: - Test controls

    /// Replace the snapshot the next `probe()` will return. Tests use
    /// this to model a device that got busier between reads.
    public func setSnapshot(_ snapshot: DeviceCapacitySnapshot) {
        lock.withLock { _snapshot = snapshot }
    }

    /// Total `probe()` calls served so far — for assertions that a
    /// consumer read the seam exactly once (or exactly N times).
    public var probeCount: Int {
        lock.withLock { _probeCount }
    }
}
