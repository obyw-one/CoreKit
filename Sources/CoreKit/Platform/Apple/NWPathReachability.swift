//
//  NWPathReachability.swift
//  CoreKit
//
//  Spec c8fa126c W3. The Apple implementation of ``ReachabilityProviding``.
//  It is in `Sources/CoreKit/Platform/`, the one subtree where a condition may
//  appear (BR-L-03), so `NetworkStatus` — which was in `CoreKitUI` and therefore
//  unreachable from a non-UI Apple consumer and absent off Apple — is no longer
//  the only way to read reachability.
//

import Foundation

#if canImport(Network)
    import Network

    /// ``ReachabilityProviding`` over `NWPathMonitor`.
    ///
    /// The classification is the one `NetworkStatus` used, unchanged, so an Apple
    /// consumer that moves from `NetworkStatus.interfaceType` to
    /// `reach.current` reads the same values (BR-L-05). The `@Published`
    /// property and the `ObservableObject` conformance are what did NOT come
    /// across: they are Combine, and the portable contract is the
    /// `AsyncStream` (BR-L-08 — this is the Net surface the operator ruled moves
    /// last, and it moves here as a NEW capability beside the old one, not as a
    /// rewrite of `NetworkStatus`'s own call sites).
    public final class NWPathReachability: ReachabilityProviding {
        private let monitor: NWPathMonitor
        private let fanout: ReachabilityFanout
        private let queue: DispatchQueue
        private let started: StartedOnce

        public init(queue: DispatchQueue = DispatchQueue(label: "corekit.reachability")) {
            self.monitor = NWPathMonitor()
            self.fanout = ReachabilityFanout()
            self.queue = queue
            self.started = StartedOnce()
            let fanout = self.fanout
            monitor.pathUpdateHandler = { path in
                let interface = Self.classify(path)
                Task { await fanout.publish(interface) }
            }
        }

        public var current: NetworkInterfaceType? {
            get async { await fanout.current }
        }

        public func updates() -> AsyncStream<NetworkInterfaceType> {
            // A detached stream cannot be built synchronously from an actor's
            // state, and the protocol's `updates()` is synchronous so a `for
            // await` reads naturally. Bridging with one buffered stream that
            // forwards from the actor's own stream keeps both true.
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
            guard await started.claim() else { return }
            monitor.start(queue: queue)
        }

        public func cancel() async {
            monitor.cancel()
            await fanout.finish()
        }

        static func classify(_ path: NWPath) -> NetworkInterfaceType {
            if path.usesInterfaceType(.wifi) {
                return .wifi
            } else if path.usesInterfaceType(.cellular) {
                return .cellular
            } else if path.usesInterfaceType(.loopback) {
                return .localhost
            } else if path.usesInterfaceType(.wiredEthernet) {
                return .ethernet
            }
            return .unknown
        }
    }
#endif
