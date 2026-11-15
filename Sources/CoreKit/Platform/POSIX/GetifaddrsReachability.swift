//
//  GetifaddrsReachability.swift
//  CoreKit
//
//  Spec c8fa126c W3. The non-Apple implementation of ``ReachabilityProviding``.
//
//  The spec's open question was "does any Linux consumer need a reachability
//  signal at all?", to be answered by naming a consumer, with
//  "`AlwaysReachable` for Linux" as the fallback. Measured 2026-11-15 across the
//  fleet (`grep -rl NetworkStatus`): flsh ×2, wabisabi ×3, shi-qa ×1 — all
//  Apple, no Linux consumer today. `AlwaysReachable` is still the wrong answer,
//  because a provider that answers `.ethernet` without looking is a fabricated
//  verdict that a caller cannot tell from a measurement. `getifaddrs(3)` is in
//  musl and glibc, costs one syscall, and answers honestly — including
//  `.unknown` when it cannot tell.
//

import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Darwin)
    import Darwin
#endif

/// ``ReachabilityProviding`` over `getifaddrs(3)`, with a polling task.
///
/// There is no POSIX equivalent of `NWPathMonitor`'s push notification that is
/// portable across musl and glibc (netlink is Linux-only and would not build for
/// a BSD or Windows target), so changes are observed by polling on
/// ``pollInterval``. The interval is a parameter, not a constant, because a
/// daemon that cares picks it and one that does not never calls `start()`.
///
/// Classification, in order, from the first interface that is `IFF_UP`,
/// `IFF_RUNNING` and not `IFF_LOOPBACK`:
/// `wlan*`/`wl*` → `.wifi`, `wwan*`/`ppp*` → `.cellular`, `eth*`/`en*` →
/// `.ethernet`, anything else up → `.unknown`. With nothing but loopback up the
/// answer is `.localhost`, which is the honest reading of a host that can reach
/// itself and nothing else — not `nil`, which means "not observed yet".
public final class GetifaddrsReachability: ReachabilityProviding {
    private let fanout: ReachabilityFanout
    private let pollInterval: Duration
    private let poller: PollerBox

    public init(pollInterval: Duration = .seconds(5)) {
        self.fanout = ReachabilityFanout()
        self.pollInterval = pollInterval
        self.poller = PollerBox()
    }

    public var current: NetworkInterfaceType? {
        get async { await fanout.current }
    }

    public func updates() -> AsyncStream<NetworkInterfaceType> {
        let fanout = self.fanout
        return AsyncStream { continuation in
            let task = Task {
                for await value in await fanout.makeStream() {
                    continuation.yield(value)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func start() async {
        let fanout = self.fanout
        let interval = pollInterval
        await poller.startIfNeeded {
            Task {
                // One reading before the first sleep, so a caller that starts and
                // immediately reads `current` is not told "not observed yet"
                // about a host whose interfaces are right there.
                await fanout.publish(Self.readInterface())
                while !Task.isCancelled {
                    // `TaskDeadline.sleep`, not `Task.sleep(for:)`: the
                    // clock-based form aborts the runtime when cancelled inside
                    // a task group, which is what the CoreKit sleep ratchet
                    // (T-04) exists to prevent.
                    try? await TaskDeadline.sleep(interval)
                    if Task.isCancelled { break }
                    await fanout.publish(Self.readInterface())
                }
            }
        }
    }

    public func cancel() async {
        await poller.cancel()
        await fanout.finish()
    }

    // MARK: - The reading

    /// One `getifaddrs` pass. `nil` only when the syscall itself failed, which is
    /// reported rather than smoothed into `.unknown`: "the probe failed" and "the
    /// host has an interface this probe does not recognise" are different facts.
    public static func readInterface() -> NetworkInterfaceType? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            AppLog.network.error("GetifaddrsReachability: getifaddrs failed (errno \(errno))")
            return nil
        }
        defer { freeifaddrs(head) }

        var best: NetworkInterfaceType?
        var sawLoopbackUp = false
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            let isUp = (flags & Int32(IFF_UP)) != 0 && (flags & Int32(IFF_RUNNING)) != 0
            guard isUp else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            if (flags & Int32(IFF_LOOPBACK)) != 0 {
                sawLoopbackUp = true
                continue
            }
            let classified = classify(interfaceName: name)
            // Prefer the most specific classification seen: a host with both
            // `eth0` and `wlan0` up is on wifi only if nothing wired answers,
            // which is the same precedence `NWPath` reports.
            if best == nil || rank(classified) < rank(best!) {
                best = classified
            }
        }

        if let best { return best }
        return sawLoopbackUp ? .localhost : .unknown
    }

    /// Name-prefix classification. Linux's predictable names (`enp0s3`, `wlp2s0`)
    /// and the classic ones (`eth0`, `wlan0`) both land correctly; musl and glibc
    /// report the same names because the kernel does.
    static func classify(interfaceName name: String) -> NetworkInterfaceType {
        if name.hasPrefix("wlan") || name.hasPrefix("wlp") || name.hasPrefix("wl") {
            return .wifi
        }
        if name.hasPrefix("wwan") || name.hasPrefix("ppp") || name.hasPrefix("rmnet") {
            return .cellular
        }
        if name.hasPrefix("eth") || name.hasPrefix("enp") || name.hasPrefix("ens") || name.hasPrefix("eno")
            || name.hasPrefix("en") {
            return .ethernet
        }
        return .unknown
    }

    private static func rank(_ interface: NetworkInterfaceType) -> Int {
        switch interface {
        case .ethernet: return 0
        case .wifi: return 1
        case .cellular: return 2
        case .localhost: return 3
        case .unknown: return 4
        }
    }
}

// MARK: - PollerBox

/// Holds the polling task so `start()` is idempotent and `cancel()` is total.
/// An actor for the same reason ``StartedOnce`` is one.
actor PollerBox {
    private var task: Task<Void, Never>?

    func startIfNeeded(_ make: () -> Task<Void, Never>) {
        guard task == nil else { return }
        task = make()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
