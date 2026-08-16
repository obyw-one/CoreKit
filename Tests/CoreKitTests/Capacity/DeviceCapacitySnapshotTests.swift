import Foundation
import Testing

@testable import CoreKit

// MARK: - Fixtures

extension DeviceCapacitySnapshot {
  /// A fully-populated fixture — every field non-nil so round-trip and
  /// field-drive tests can assert every slot survived transport.
  fileprivate static let macFullyPopulated = DeviceCapacitySnapshot(
    totalRAM: 64 * 1024 * 1024 * 1024,  // 64 GiB
    availableNow: 12 * 1024 * 1024 * 1024,  // 12 GiB free-ish
    swapInUse: 40 * 1024 * 1024 * 1024,  // 40 GiB in swap
    thermalState: .fair,
    chipClass: "Apple M2 Max",
    gpuWorkingSetLimit: 48 * 1024 * 1024 * 1024,  // 48 GiB
    basis: .deviceWide
  )
}

// MARK: - DeviceCapacitySnapshotTests
//
// Fixture-driven contract tests for the snapshot value and the
// `DeviceCapacityProbing` seam, plus the T-CP-06 ratchet grep over the
// CoreKit source tree. Live-hardware coverage (T-CP-04, T-CP-07) lives
// in `PlatformCapacityProberTests`.

@Suite("DeviceCapacitySnapshot")
struct DeviceCapacitySnapshotTests {

  // T-CP-01 — the lossy-transport silent-fail class: a `nil` that turns
  // into `0` at any storage or IPC boundary silently converts
  // "unmeasured" into "measured as zero". Round-trip is the fence.
  @Test("T-CP-01 snapshot round-trips every field including nils and basis")
  func snapshotRoundTrips() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let full = DeviceCapacitySnapshot.macFullyPopulated
    let fullData = try encoder.encode(full)
    let fullDecoded = try decoder.decode(DeviceCapacitySnapshot.self, from: fullData)
    #expect(fullDecoded == full)

    // A per-process snapshot with intentional nils — the interesting
    // case for the lossy-transport class.
    let partial = DeviceCapacitySnapshot(
      totalRAM: 6 * 1024 * 1024 * 1024,
      availableNow: 900 * 1024 * 1024,
      swapInUse: nil,
      thermalState: .critical,
      chipClass: nil,
      gpuWorkingSetLimit: nil,
      basis: .perProcess
    )
    let partialData = try encoder.encode(partial)
    let partialDecoded = try decoder.decode(DeviceCapacitySnapshot.self, from: partialData)
    #expect(partialDecoded == partial)
    #expect(partialDecoded.swapInUse == nil)
    #expect(partialDecoded.chipClass == nil)
    #expect(partialDecoded.gpuWorkingSetLimit == nil)
    #expect(partialDecoded.basis == .perProcess)

    // Empty-but-basis: proves basis alone survives transport too.
    let bare = DeviceCapacitySnapshot(basis: .deviceWide)
    let bareData = try encoder.encode(bare)
    let bareDecoded = try decoder.decode(DeviceCapacitySnapshot.self, from: bareData)
    #expect(bareDecoded == bare)
    #expect(bareDecoded.totalRAM == nil)
  }

  // T-CP-02 — every field a consumer reads MUST trace to the injected
  // prober. If a call site quietly reads ambient device state on the
  // side, tests pass against fixtures while production diverges.
  @Test("T-CP-02 every snapshot field originates from the injected prober")
  func mockProberDrivesFields() {
    let fixture = DeviceCapacitySnapshot.macFullyPopulated
    let prober: any DeviceCapacityProbing = MockCapacityProber(fixture)

    let read = prober.probe()

    #expect(read.totalRAM == fixture.totalRAM)
    #expect(read.availableNow == fixture.availableNow)
    #expect(read.swapInUse == fixture.swapInUse)
    #expect(read.thermalState == fixture.thermalState)
    #expect(read.chipClass == fixture.chipClass)
    #expect(read.gpuWorkingSetLimit == fixture.gpuWorkingSetLimit)
    #expect(read.basis == fixture.basis)
    // Full equality is the ratchet against a future field that gets
    // added but forgotten in either the mock or the snapshot init.
    #expect(read == fixture)
  }

  // T-CP-03 — the stale-total-as-live silent-fail class, and the exact
  // reason this wave exists: a 64 GB machine carrying 40 GB of swap
  // must NOT read as idle just because totalRAM hasn't changed.
  @Test("T-CP-03 live pressure moves availableNow, not totalRAM")
  func livePressureChangesAvailableNow() {
    let idle = DeviceCapacitySnapshot(
      totalRAM: 64 * 1024 * 1024 * 1024,
      availableNow: 30 * 1024 * 1024 * 1024,
      swapInUse: 0,
      basis: .deviceWide
    )
    let pressed = DeviceCapacitySnapshot(
      totalRAM: 64 * 1024 * 1024 * 1024,  // same machine
      availableNow: 2 * 1024 * 1024 * 1024,  // pressure dropped it
      swapInUse: 40 * 1024 * 1024 * 1024,  // 40 GB in swap
      basis: .deviceWide
    )
    let prober = MockCapacityProber(idle)

    let first = prober.probe()
    prober.setSnapshot(pressed)
    let second = prober.probe()

    #expect(first.totalRAM == second.totalRAM)
    #expect(first.availableNow != second.availableNow)
    #expect((second.availableNow ?? .max) < (first.availableNow ?? 0))
  }

  // T-CP-05 — a probe that cannot measure a field yields `nil`, never
  // a substituted constant. This is the substituted-default silent-fail
  // class: an 8-GiB fallback that reads downstream as a real measurement
  // is exactly how a wrong verdict ships confidently.
  @Test("T-CP-05 unmeasurable fields are nil, never a substituted constant")
  func unmeasurableFieldIsNil() {
    // A prober where the platform could not read anything but basis.
    let allNilExceptBasis = DeviceCapacitySnapshot(basis: .perProcess)
    let prober: any DeviceCapacityProbing = MockCapacityProber(allNilExceptBasis)

    let read = prober.probe()

    #expect(read.totalRAM == nil)
    #expect(read.availableNow == nil)
    #expect(read.swapInUse == nil)
    #expect(read.thermalState == nil)
    #expect(read.chipClass == nil)
    #expect(read.gpuWorkingSetLimit == nil)
    // basis is required; it is not a measurement and therefore
    // is not in the nil-safety contract.
    #expect(read.basis == .perProcess)
  }

  // T-CP-06 — the ambient-read-leak silent-fail class ratchet.
  // Direct capacity syscalls (`sysctl`, `host_statistics`,
  // `os_proc_available_memory`) are allowed in exactly ONE file:
  // `PlatformCapacityProber.swift`. If any other CoreKit source
  // starts calling them directly, production and fixtures drift and
  // only production is wrong. This grep-at-test-time catches that
  // before it lands.
  @Test("T-CP-06 direct capacity syscalls are confined to the platform prober")
  func noDirectSyscallOutsideProber() throws {
    let sourcesDir = try Self.locateCoreKitSources()
    let allowedFile = "PlatformCapacityProber.swift"
    // Match invocation form (`identifier(`) rather than bare names —
    // the failure mode we're preventing is a CALL past the seam, not
    // a comment mentioning the symbol as prose. Each family (sysctl,
    // host_statistics, os_proc_available_memory) is enumerated with
    // every entry-point spelling so no dialect slips through.
    let bannedSubstrings = [
      "sysctl(",
      "sysctlbyname(",
      "host_statistics(",
      "host_statistics64(",
      "os_proc_available_memory(",
    ]

    let enumerator = FileManager.default.enumerator(
      at: sourcesDir,
      includingPropertiesForKeys: nil
    )
    var offenders: [(file: String, symbol: String)] = []
    var scanned = 0
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      scanned += 1
      guard url.lastPathComponent != allowedFile else { continue }
      let contents = try String(contentsOf: url, encoding: .utf8)
      for symbol in bannedSubstrings where contents.contains(symbol) {
        offenders.append((url.path, symbol))
      }
    }

    // Sanity: if the scan finds no Swift files at all, the ratchet
    // is silently green — that would be the exact false-pass shape
    // this test exists to prevent, only against itself.
    #expect(scanned > 0, "T-CP-06 ratchet scanned no files — locator drift?")
    #expect(
      offenders.isEmpty,
      "Direct capacity syscalls MUST live only in \(allowedFile). Offenders: \(offenders)"
    )
  }

  // MARK: - Helpers

  /// Locate `Sources/CoreKit/` from this test file's on-disk path.
  /// Swift Testing runs the binary out-of-tree, so `#filePath` is the
  /// stable reference point back to the working tree.
  private static func locateCoreKitSources() throws -> URL {
    let testFile = URL(fileURLWithPath: #filePath)
    // .../Tests/CoreKitTests/Capacity/DeviceCapacitySnapshotTests.swift
    //   → .../Tests/CoreKitTests/Capacity
    //   → .../Tests/CoreKitTests
    //   → .../Tests
    //   → .../  (project root)
    let projectRoot =
      testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourcesDir =
      projectRoot
      .appendingPathComponent("Sources")
      .appendingPathComponent("CoreKit")

    var isDir: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: sourcesDir.path, isDirectory: &isDir),
      isDir.boolValue
    else {
      throw RatchetLocateError.sourcesNotFound(sourcesDir.path)
    }
    return sourcesDir
  }

  private enum RatchetLocateError: Error, CustomStringConvertible {
    case sourcesNotFound(String)
    var description: String {
      switch self {
      case .sourcesNotFound(let path):
        return "CoreKit sources directory not found at \(path)"
      }
    }
  }
}
