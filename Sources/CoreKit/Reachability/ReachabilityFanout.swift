//
//  ReachabilityFanout.swift
//  CoreKit
//
//  Spec c8fa126c W3. The part of a ``ReachabilityProviding`` implementation that
//  is NOT platform-specific: holding the last observed value, handing out
//  independent `AsyncStream`s and fanning one change out to all of them.
//
//  It lives in the portable target, unconditionally, and both the Apple and the
//  POSIX provider own one. Duplicating it per platform is how two code paths
//  drift apart on the one behaviour a test can actually pin
//  ([[sharing-the-list-while-duplicating-the-predicate-makes-a-check-and-its-remedy-loop]]).
//

import Foundation

/// Last-value store plus multicast for reachability observations.
///
/// An actor, not a lock: the only reason a lock would be needed is a
/// synchronous getter, and ``ReachabilityProviding/current`` is `async`
/// precisely so none is
/// ([[unchecked-sendable-on-a-recorder-is-a-symptom-make-the-callback-async]]).
public actor ReachabilityFanout {
    private var value: NetworkInterfaceType?
    private var continuations: [UUID: AsyncStream<NetworkInterfaceType>.Continuation] = [:]

    public init() {}

    /// The last observed interface, or `nil` if nothing has been observed.
    public var current: NetworkInterfaceType? { value }

    /// Record an observation and deliver it to every live stream.
    ///
    /// A repeat of the current value is delivered too: a caller that wants
    /// change-only semantics can compare, but a caller that wants "the monitor
    /// is alive and still says wifi" cannot recover a swallowed event.
    public func publish(_ interface: NetworkInterfaceType?) async {
        value = interface
        // The shared process-wide store predates this capability and is read
        // directly by CacheRepository; keep it fed so the capability is the one
        // writer rather than a second, competing one.
        await NetworkReachabilityStore.shared.update(interface)
        guard let interface else { return }
        for continuation in continuations.values {
            continuation.yield(interface)
        }
    }

    /// A new independent stream. Dropping it unsubscribes.
    public func makeStream() -> AsyncStream<NetworkInterfaceType> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.remove(id) }
            }
            if let value {
                continuation.yield(value)
            }
        }
    }

    /// Finish every live stream and forget them.
    public func finish() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func remove(_ id: UUID) {
        continuations[id] = nil
    }
}
