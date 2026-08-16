import Foundation

// MARK: - DeviceCapacityProbing

/// The one seam through which every capacity read goes (BR-CP-04). Call
/// sites never touch `sysctl`, `host_statistics64`, or
/// `os_proc_available_memory` directly — those symbols live inside
/// `PlatformCapacityProber.swift` and only there, and the ratchet test
/// `T-CP-06` enforces that with a source grep so a future call site can't
/// silently drift the two paths (ambient-read-leak silent-fail class).
///
/// `probe()` intentionally does NOT throw: a probe that cannot read a
/// value reports `nil` on that field (BR-CP-06). Throwing would put
/// callers in the position of choosing a "safe" default, which is exactly
/// how the substituted-default silent-fail class ships.
public protocol DeviceCapacityProbing: Sendable {

  /// Read one fresh snapshot at this instant. Never cached — the same
  /// device gives a different honest answer idle vs under pressure
  /// (BR-CP-03), so callers control cadence.
  func probe() -> DeviceCapacitySnapshot
}
