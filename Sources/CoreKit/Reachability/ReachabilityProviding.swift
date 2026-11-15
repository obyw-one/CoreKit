//
//  ReachabilityProviding.swift
//  CoreKit
//
//  Spec c8fa126c W3, BR-L-02: reachability is one protocol in the portable
//  target over the Foundation-only ``NetworkInterfaceType`` vocabulary that
//  already lived in `Sources/CoreKit/Network/`. The Apple implementation wraps
//  `NWPathMonitor`; the POSIX one reads `getifaddrs`. Both are registered by
//  ``CoreKitPlatformAssembly`` and neither is named by a caller (BR-L-04).
//
//  The contract is an `AsyncStream`, not a Combine publisher: an `AsyncSequence`
//  is the fleet's portable reactive surface
//  ([[two-buses-in-process-eventbus-replaces-combine-nats-is-the-distributed-bus]]).
//

import Foundation

/// The current network interface, and a stream of changes to it.
///
/// ```swift
/// let reach = try resolve((any ReachabilityProviding).self)
/// if await reach.current == .cellular { … }
/// for await change in reach.updates { … }
/// ```
///
/// `current` is `async` because both implementations hold their value in an
/// actor: the Apple one is fed by `NWPathMonitor`'s callback queue, the POSIX one
/// by a polling task, and in neither case can a synchronous getter be correct
/// without a lock.
///
/// A consumer that resolves this slot without registering
/// ``CoreKitPlatformAssembly`` gets `ContainerError.notRegistered` (BR-L-06).
/// There is deliberately no `AlwaysReachable` stand-in: a provider that answers
/// `.ethernet` without looking fabricates a verdict
/// ([[a-try-with-a-literal-fallback-fabricates-a-verdict]]).
public protocol ReachabilityProviding: Sendable {
    /// The interface the host is currently reaching the network through, or
    /// `nil` when nothing has been observed yet.
    var current: NetworkInterfaceType? { get async }

    /// Every observed change, from the moment the stream is created.
    ///
    /// Each call returns an independent stream; a provider fans out to all live
    /// streams. Dropping a stream unsubscribes it.
    func updates() -> AsyncStream<NetworkInterfaceType>

    /// Begin observing. Idempotent: a second call does not create a second
    /// monitor.
    func start() async

    /// Stop observing and finish every live stream.
    func cancel() async
}
