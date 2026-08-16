import Foundation

#if canImport(Darwin)
  import Darwin
  import Darwin.Mach
#endif
#if canImport(Metal)
  import Metal
#endif

// MARK: - PlatformCapacityProber

/// The one place in CoreKit that talks to real hardware — the ONLY file
/// where `sysctl`, `host_statistics64`, and `os_proc_available_memory`
/// may appear (BR-CP-04, enforced by ratchet `T-CP-06`).
///
/// The `#if os(...)` split lives inside the type instead of splitting the
/// file per-platform so the seam (`DeviceCapacityProbing`) stays a single
/// implementation, and so the ratchet grep has a single obvious target
/// filename to allow-list.
///
/// Every read defends against BR-CP-06: a failed syscall yields `nil` on
/// that snapshot field and logs, and never substitutes a plausible
/// constant that a downstream verdict could mistake for a measurement.
public struct PlatformCapacityProber: DeviceCapacityProbing {

  public init() {}

  // MARK: - Probe

  public func probe() -> DeviceCapacitySnapshot {
    #if os(macOS)
      return probeMacOS()
    #elseif os(iOS)
      return probeIOS()
    #else
      // Unsupported build target: report nothing rather than fake
      // anything. `.deviceWide` is the only conservative basis to
      // choose here — a `.perProcess` claim would misrepresent an
      // environment that has no jetsam limit.
      return DeviceCapacitySnapshot(basis: .deviceWide)
    #endif
  }

  // MARK: - macOS

  #if os(macOS)
    private func probeMacOS() -> DeviceCapacitySnapshot {
      DeviceCapacitySnapshot(
        totalRAM: readTotalRAMMacOS(),
        availableNow: readAvailableMemoryMacOS(),
        swapInUse: readSwapInUseMacOS(),
        thermalState: readThermalState(),
        chipClass: readChipClassMacOS(),
        gpuWorkingSetLimit: readGPUWorkingSetLimit(),
        basis: .deviceWide
      )
    }

    private func readTotalRAMMacOS() -> UInt64? {
      var value: UInt64 = 0
      var size = MemoryLayout<UInt64>.size
      let rc = sysctlbyname("hw.memsize", &value, &size, nil, 0)
      guard rc == 0 else {
        AppLog.app.error("PlatformCapacityProber: hw.memsize failed (\(rc))")
        return nil
      }
      return value
    }

    private func readAvailableMemoryMacOS() -> UInt64? {
      // `free + inactive` is the reusable pool a new allocation could
      // draw on without paging out an active page; wired + active +
      // compressed are not reclaimable in the same sense. This is the
      // number that MOVES when the machine goes from idle to pressed,
      // which is exactly what BR-CP-03 requires `availableNow` to be.
      var stats = vm_statistics64()
      var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
      )
      let host = mach_host_self()
      let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
          host_statistics64(host, HOST_VM_INFO64, rebound, &count)
        }
      }
      guard kr == KERN_SUCCESS else {
        AppLog.app.error("PlatformCapacityProber: host_statistics64 failed (\(kr))")
        return nil
      }
      let pageSize = UInt64(getpagesize())
      return (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * pageSize
    }

    private func readSwapInUseMacOS() -> UInt64? {
      var xsw = xsw_usage()
      var size = MemoryLayout<xsw_usage>.size
      let rc = sysctlbyname("vm.swapusage", &xsw, &size, nil, 0)
      guard rc == 0 else {
        AppLog.app.error("PlatformCapacityProber: vm.swapusage failed (\(rc))")
        return nil
      }
      return xsw.xsu_used
    }

    private func readChipClassMacOS() -> String? {
      // Two-call sysctl idiom: first call sizes the buffer, second
      // fills it. Any short-read shows up as a non-zero rc and reads
      // as `nil` (BR-CP-06), never as a truncated garbage string.
      var size = 0
      guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
        return nil
      }
      var buffer = [UInt8](repeating: 0, count: size)
      guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
        return nil
      }
      // Drop the C null terminator before decoding — Swift 6's
      // `String(decoding:as:)` treats the null byte as content.
      let payload = buffer.prefix { $0 != 0 }
      return String(decoding: payload, as: UTF8.self)
    }
  #endif  // os(macOS)

  // MARK: - iOS

  #if os(iOS)
    private func probeIOS() -> DeviceCapacitySnapshot {
      // `ProcessInfo.physicalMemory` is the DEVICE's hardware total —
      // a fact worth reporting, but under `.perProcess` basis it MUST
      // NOT be read as a spendable budget by any consumer (BR-CP-02).
      DeviceCapacitySnapshot(
        totalRAM: ProcessInfo.processInfo.physicalMemory,
        availableNow: readAvailableMemoryIOS(),
        swapInUse: nil,  // no sandbox-legal source (BR-CP-05)
        thermalState: readThermalState(),
        chipClass: nil,  // no sandbox-legal source (BR-CP-05)
        gpuWorkingSetLimit: readGPUWorkingSetLimit(),
        basis: .perProcess
      )
    }

    private func readAvailableMemoryIOS() -> UInt64? {
      // `os_proc_available_memory` returns bytes of headroom before
      // the current process trips the jetsam limit — the ONE number
      // that answers "can this process load that model" on iOS.
      // Returns 0 on error per docs; map to `nil` per BR-CP-06.
      let value = os_proc_available_memory()
      guard value > 0 else {
        AppLog.app.error("PlatformCapacityProber: os_proc_available_memory returned 0")
        return nil
      }
      return UInt64(value)
    }
  #endif  // os(iOS)

  // MARK: - Shared Apple readers

  #if os(macOS) || os(iOS)
    private func readThermalState() -> DeviceCapacitySnapshot.ThermalState? {
      switch ProcessInfo.processInfo.thermalState {
      case .nominal: return .nominal
      case .fair: return .fair
      case .serious: return .serious
      case .critical: return .critical
      @unknown default: return nil
      }
    }

    private func readGPUWorkingSetLimit() -> UInt64? {
      #if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return device.recommendedMaxWorkingSetSize
      #else
        return nil
      #endif
    }
  #endif
}
