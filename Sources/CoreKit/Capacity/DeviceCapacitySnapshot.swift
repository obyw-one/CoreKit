import Foundation

// MARK: - CapacityBasis

/// Whether a `DeviceCapacitySnapshot`'s numbers describe the WHOLE device
/// or JUST the current process — the difference between macOS and iOS.
///
/// The parent spec's founding fixture (a 64 GB M2 Max carrying 40 GB of
/// swap) is device-wide; the same numbers on iOS would be bounded by the
/// per-process jetsam limit and cannot be spent as if they were the whole
/// machine. Consumers that pick a model MUST read this before treating
/// `availableNow` as a budget (BR-CP-02).
public enum CapacityBasis: String, Sendable, Equatable, Codable {
    /// Numbers reflect the whole device (macOS: `hw.memsize`, host stats).
    case deviceWide
    /// Numbers reflect this process only (iOS: `os_proc_available_memory`
    /// against the jetsam limit). `ProcessInfo.physicalMemory` is a
    /// hardware fact under this basis, NOT a spendable budget.
    case perProcess
}

// MARK: - DeviceCapacitySnapshot

/// One honest, timestampable read of what a device can spend on a model —
/// W1 of the capacity/model-fit spec, extracted to CoreKit because a
/// memory probe carries no AI concepts (parent spec BR-CF-07).
///
/// Every field is `Optional` for exactly one reason: on a platform where
/// the field cannot be measured legally (BR-CP-05), the honest answer is
/// "unmeasured" — reported as `nil`, never faked with a plausible
/// constant (BR-CP-06). A downstream `nil` reads as "not enough
/// information to decide"; a substituted default reads as a measurement
/// and lets a wrong verdict ship silently.
///
/// `basis` is required: without it a consumer can accidentally read a
/// per-process number against a device-wide budget and over-commit memory
/// by an order of magnitude (the basis-confusion silent-fail class).
///
/// `Sendable`, `Equatable`, `Codable` per
/// [[json-means-codable-typed-model]] — the same shape can be logged,
/// shipped over IPC, or persisted, and a round-trip preserves `nil` vs
/// `0` (the lossy-transport silent-fail class).
public struct DeviceCapacitySnapshot: Sendable, Equatable, Codable {
    /// Total device RAM in bytes. On macOS this is `hw.memsize` (a
    /// hardware fact). On iOS this is `ProcessInfo.physicalMemory` —
    /// still a hardware fact, and under `.perProcess` basis it MUST NOT
    /// be read as a spendable budget (BR-CP-02).
    public let totalRAM: UInt64?

    /// Currently available memory in bytes, interpreted under `basis`.
    /// The parent spec's fixture demands this be a live number, not a
    /// derivation of `totalRAM` — a swap-saturated machine reads
    /// completely differently here than it does in `totalRAM`.
    public let availableNow: UInt64?

    /// Bytes currently paged out to swap. macOS-only; `nil` on iOS where
    /// no sandbox-legal API exposes it (BR-CP-05).
    public let swapInUse: UInt64?

    /// Current thermal state, when the platform surfaces one. Both
    /// macOS and iOS expose `ProcessInfo.thermalState`; `nil` when the
    /// value cannot be mapped (`@unknown default`).
    public let thermalState: ThermalState?

    /// Marketing/chip class string (e.g. "Apple M2 Max"). macOS only
    /// via `machdep.cpu.brand_string`; iOS is sandbox-blocked and reads
    /// `nil` (BR-CP-05). Downstream heuristics MUST treat `nil` as
    /// "chip unknown" — never fall back to a hardcoded "assume M2".
    public let chipClass: String?

    /// Metal `recommendedMaxWorkingSetSize` in bytes — the GPU's honest
    /// per-command-buffer working-set ceiling. `nil` on platforms
    /// without Metal or when the default device is unavailable.
    public let gpuWorkingSetLimit: UInt64?

    /// Whether the numbers above describe the WHOLE device or JUST this
    /// process. Non-optional by design: a snapshot with unknown basis is
    /// unreadable, and a default would risk basis confusion.
    public let basis: CapacityBasis

    public init(
        totalRAM: UInt64? = nil,
        availableNow: UInt64? = nil,
        swapInUse: UInt64? = nil,
        thermalState: ThermalState? = nil,
        chipClass: String? = nil,
        gpuWorkingSetLimit: UInt64? = nil,
        basis: CapacityBasis
    ) {
        self.totalRAM = totalRAM
        self.availableNow = availableNow
        self.swapInUse = swapInUse
        self.thermalState = thermalState
        self.chipClass = chipClass
        self.gpuWorkingSetLimit = gpuWorkingSetLimit
        self.basis = basis
    }

    // MARK: - ThermalState

    /// Codable mirror of `ProcessInfo.ThermalState` — the system-level
    /// enum is `RawRepresentable` as `Int` and not Codable-friendly for
    /// storage/transport, so the snapshot carries a stable string tag.
    public enum ThermalState: String, Sendable, Equatable, Codable {
        case nominal
        case fair
        case serious
        case critical
    }
}
