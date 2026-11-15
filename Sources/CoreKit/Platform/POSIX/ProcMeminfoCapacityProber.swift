//
//  ProcMeminfoCapacityProber.swift
//  CoreKit
//
//  Spec c8fa126c, the operator's 1:1 rule applied to an existing capability:
//  `DeviceCapacityProbing` was already a protocol with an Apple implementation,
//  and off Apple `PlatformCapacityProber.probe()` returned
//  `DeviceCapacitySnapshot(basis: .deviceWide)` — every field nil. That is
//  honest (BR-CP-06: never fake a constant) but it is not parity: a Linux host
//  running the same code could not answer "can this box afford this model".
//
//  `/proc/meminfo` is the Linux answer and it needs no syscall, no Darwin and no
//  `#if os` beyond this file's own: it is a file read.
//

import Foundation

/// ``DeviceCapacityProbing`` over `/proc/meminfo` and `/sys/class/thermal`.
///
/// Fields, and what each maps to:
/// - `totalRAM` ← `MemTotal` (kB → bytes).
/// - `availableNow` ← `MemAvailable`, which is the kernel's own estimate of what
///   a new allocation can have. `MemFree` is NOT used: it excludes reclaimable
///   page cache and would understate capacity by gigabytes on any warm host.
/// - `swapInUse` ← `SwapTotal - SwapFree`.
/// - `thermalState` ← the hottest `/sys/class/thermal/thermal_zone*/temp`,
///   bucketed. `nil` when no zone is readable, which is normal in a container.
/// - `chipClass` ← `nil`. There is no Linux equivalent of the Apple-silicon
///   generation string, and inventing one from `/proc/cpuinfo`'s model name
///   would put a value in a field whose domain is Apple's (BR-CP-06).
/// - `gpuWorkingSetLimit` ← `nil`. No portable Linux source; a per-vendor read
///   (`nvidia-smi`, `/sys/class/drm`) is a different capability.
/// - `basis` ← `.deviceWide` with no cgroup limit, `.perProcess` when a cgroup v2
///   `memory.max` is set, because that limit is this process's ceiling and not
///   the box's.
///
/// Every read is independently optional: a missing key yields `nil` for that
/// field and never a substituted constant.
public struct ProcMeminfoCapacityProber: DeviceCapacityProbing {
    private let meminfoPath: String
    private let cgroupMaxPath: String
    private let thermalRoot: String

    /// - Parameters:
    ///   - meminfoPath: Overridable so a test can feed a fixture rather than the
    ///     host's own kernel — the probe is pure given its paths.
    ///   - cgroupMaxPath: cgroup v2 `memory.max` for this process.
    ///   - thermalRoot: Directory holding `thermal_zone*/temp`.
    public init(
        meminfoPath: String = "/proc/meminfo",
        cgroupMaxPath: String = "/sys/fs/cgroup/memory.max",
        thermalRoot: String = "/sys/class/thermal"
    ) {
        self.meminfoPath = meminfoPath
        self.cgroupMaxPath = cgroupMaxPath
        self.thermalRoot = thermalRoot
    }

    public func probe() -> DeviceCapacitySnapshot {
        let fields = Self.parseMeminfo(at: meminfoPath)
        let cgroupLimit = Self.readCgroupLimit(at: cgroupMaxPath)

        let total: UInt64?
        let basis: CapacityBasis
        if let cgroupLimit {
            // A cgroup ceiling is what this process may spend, which is exactly
            // what `.perProcess` means on iOS under jetsam.
            total = cgroupLimit
            basis = .perProcess
        } else {
            total = fields["MemTotal"]
            basis = .deviceWide
        }

        let available: UInt64?
        if let limit = cgroupLimit, let hostAvailable = fields["MemAvailable"] {
            // Inside a cgroup, the host's MemAvailable can exceed the ceiling;
            // the smaller of the two is the only one a caller can spend.
            available = min(limit, hostAvailable)
        } else {
            available = fields["MemAvailable"]
        }

        var swapInUse: UInt64?
        if let swapTotal = fields["SwapTotal"], let swapFree = fields["SwapFree"] {
            swapInUse = swapTotal >= swapFree ? swapTotal - swapFree : 0
        }

        return DeviceCapacitySnapshot(
            totalRAM: total,
            availableNow: available,
            swapInUse: swapInUse,
            thermalState: Self.readThermalState(root: thermalRoot),
            chipClass: nil,
            gpuWorkingSetLimit: nil,
            basis: basis
        )
    }

    // MARK: - Parsing (pure, testable)

    /// `MemTotal:  16316920 kB` → `["MemTotal": 16708525_. ..]`, in BYTES.
    /// A line whose value is not an integer, or whose unit is not `kB`, is
    /// skipped rather than guessed at.
    static func parseMeminfo(at path: String) -> [String: UInt64] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            AppLog.app.warning("ProcMeminfoCapacityProber: \(path) is not readable")
            return [:]
        }
        return parseMeminfo(text: text)
    }

    static func parseMeminfo(text: String) -> [String: UInt64] {
        var out: [String: UInt64] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
            let rest = line[line.index(after: colon)...]
                .split(separator: " ", omittingEmptySubsequences: true)
            guard let first = rest.first, let value = UInt64(first) else { continue }
            if rest.count >= 2 {
                guard rest[1] == "kB" else { continue }
                out[key] = value * 1024
            } else {
                out[key] = value
            }
        }
        return out
    }

    /// cgroup v2 `memory.max` holds either a byte count or the literal `max`,
    /// which means "no limit" and must read as no limit, not as 0.
    static func readCgroupLimit(at path: String) -> UInt64? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "max" { return nil }
        return UInt64(trimmed)
    }

    /// Hottest readable zone, bucketed. The thresholds mirror the shape of
    /// Apple's four-step `ProcessInfo.thermalState` so a caller's comparison
    /// means the same thing on both; they are millidegrees Celsius.
    static func readThermalState(root: String) -> DeviceCapacitySnapshot.ThermalState? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        var hottest: Int?
        for entry in entries where entry.hasPrefix("thermal_zone") {
            let path = root + "/" + entry + "/temp"
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
                  let milli = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }
            if hottest == nil || milli > hottest! { hottest = milli }
        }
        guard let hottest else { return nil }
        return bucket(milliCelsius: hottest)
    }

    static func bucket(milliCelsius: Int) -> DeviceCapacitySnapshot.ThermalState {
        switch milliCelsius {
        case ..<60_000: return .nominal
        case ..<80_000: return .fair
        case ..<95_000: return .serious
        default: return .critical
        }
    }
}
