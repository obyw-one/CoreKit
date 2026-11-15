import Foundation
import Testing
@testable import CoreKit

/// Spec c8fa126c: the Linux arm of ``DeviceCapacityProbing``, which used to
/// return a snapshot with every field `nil` — honest, but not parity. Every test
/// here feeds a FIXTURE path, so it runs on macOS and on Linux and reads the
/// same bytes: the probe is pure given its paths.
@Suite("ProcMeminfoCapacityProber")
struct ProcMeminfoCapacityProberTests {
    /// A real `/proc/meminfo` head from a 16 GB x86_64 host.
    private static let meminfo = """
    MemTotal:       16316920 kB
    MemFree:          321244 kB
    MemAvailable:    9033116 kB
    Buffers:          178904 kB
    Cached:          8123412 kB
    SwapCached:         1024 kB
    SwapTotal:       2097148 kB
    SwapFree:        1835008 kB
    Dirty:              1120 kB
    HugePages_Total:       0
    """

    private func write(_ contents: String, as name: String) throws -> String {
        let dir = URL.temporaryDirectory.appending(path: "procmeminfo-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test("kB values become bytes and a non-kB unit is skipped, never guessed")
    func parsesUnits() {
        let fields = ProcMeminfoCapacityProber.parseMeminfo(text: Self.meminfo)
        #expect(fields["MemTotal"] == 16_316_920 * 1024)
        #expect(fields["MemAvailable"] == 9_033_116 * 1024)
        #expect(fields["HugePages_Total"] == 0, "a unitless count is taken as-is")
        #expect(fields["NotThere"] == nil)
    }

    @Test("a malformed line is skipped rather than parsed into a plausible number")
    func malformedLinesAreSkipped() {
        let fields = ProcMeminfoCapacityProber.parseMeminfo(text: """
        MemTotal:       not-a-number kB
        MemAvailable:    4096 MB
        SwapTotal:       1024 kB
        """)
        #expect(fields["MemTotal"] == nil)
        #expect(fields["MemAvailable"] == nil, "MB is not kB; a 1024x error is worse than no answer")
        #expect(fields["SwapTotal"] == 1024 * 1024)
    }

    @Test("a device-wide snapshot: totalRAM, availableNow and swapInUse, basis .deviceWide")
    func deviceWideSnapshot() async throws {
        let path = try write(Self.meminfo, as: "meminfo")
        let sut = ProcMeminfoCapacityProber(
            meminfoPath: path,
            cgroupMaxPath: "/nonexistent/memory.max",
            thermalRoot: "/nonexistent/thermal"
        )
        let snap = await sut.probe()
        #expect(snap.totalRAM == 16_316_920 * 1024)
        #expect(snap.availableNow == 9_033_116 * 1024)
        #expect(snap.swapInUse == (2_097_148 - 1_835_008) * 1024)
        #expect(snap.basis == .deviceWide)
        #expect(snap.chipClass == nil, "there is no Linux equivalent; nil, never an invented string")
        #expect(snap.gpuWorkingSetLimit == nil)
        #expect(snap.thermalState == nil, "no readable zone must read as unmeasured")
    }

    @Test("a cgroup ceiling makes the basis .perProcess and caps availableNow")
    func cgroupLimitIsPerProcess() async throws {
        let meminfoPath = try write(Self.meminfo, as: "meminfo")
        let cgroupPath = try write("2147483648\n", as: "memory.max")
        let sut = ProcMeminfoCapacityProber(
            meminfoPath: meminfoPath, cgroupMaxPath: cgroupPath, thermalRoot: "/nonexistent"
        )
        let snap = await sut.probe()
        #expect(snap.basis == .perProcess, "a cgroup ceiling is this process's limit, not the box's")
        #expect(snap.totalRAM == 2_147_483_648)
        #expect(snap.availableNow == 2_147_483_648, "the host's 8.6 GB cannot be spent past a 2 GB ceiling")
    }

    @Test("cgroup 'max' means no limit, not a limit of zero")
    func cgroupMaxMeansUnlimited() async throws {
        let meminfoPath = try write(Self.meminfo, as: "meminfo")
        let cgroupPath = try write("max\n", as: "memory.max")
        let sut = ProcMeminfoCapacityProber(
            meminfoPath: meminfoPath, cgroupMaxPath: cgroupPath, thermalRoot: "/nonexistent"
        )
        let snap = await sut.probe()
        #expect(snap.basis == .deviceWide)
        #expect(snap.totalRAM == 16_316_920 * 1024)
        #expect(ProcMeminfoCapacityProber.readCgroupLimit(at: cgroupPath) == nil)
    }

    @Test("an unreadable meminfo yields all-nil and a .deviceWide basis, never zeros")
    func unreadableMeminfoIsUnmeasured() async {
        let sut = ProcMeminfoCapacityProber(
            meminfoPath: "/nonexistent/meminfo", cgroupMaxPath: "/nonexistent", thermalRoot: "/nonexistent"
        )
        let snap = await sut.probe()
        #expect(snap.totalRAM == nil)
        #expect(snap.availableNow == nil)
        #expect(snap.swapInUse == nil)
        #expect(snap.basis == .deviceWide)
    }

    @Test("thermal bucketing is monotonic and matches Apple's four steps")
    func thermalBuckets() {
        #expect(ProcMeminfoCapacityProber.bucket(milliCelsius: 35_000) == .nominal)
        #expect(ProcMeminfoCapacityProber.bucket(milliCelsius: 59_999) == .nominal)
        #expect(ProcMeminfoCapacityProber.bucket(milliCelsius: 60_000) == .fair)
        #expect(ProcMeminfoCapacityProber.bucket(milliCelsius: 79_999) == .fair)
        #expect(ProcMeminfoCapacityProber.bucket(milliCelsius: 80_000) == .serious)
        #expect(ProcMeminfoCapacityProber.bucket(milliCelsius: 94_999) == .serious)
        #expect(ProcMeminfoCapacityProber.bucket(milliCelsius: 95_000) == .critical)
        #expect(ProcMeminfoCapacityProber.bucket(milliCelsius: 110_000) == .critical)
    }

    @Test("the hottest readable zone wins and an unreadable one is skipped")
    func thermalReadsTheHottestZone() throws {
        let root = URL.temporaryDirectory.appending(path: "thermal-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        for (zone, temp) in [("thermal_zone0", "41000"), ("thermal_zone1", "82500"), ("thermal_zone2", "oops")] {
            let dir = root.appending(path: zone, directoryHint: .isDirectory)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try temp.write(to: dir.appending(path: "temp"), atomically: true, encoding: .utf8)
        }
        #expect(ProcMeminfoCapacityProber.readThermalState(root: root.path) == .serious)
        #expect(ProcMeminfoCapacityProber.readThermalState(root: "/nonexistent") == nil)
    }
}
