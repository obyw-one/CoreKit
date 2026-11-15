//
//  InMemoryEventBusProvider.swift
//  CoreKit
//
//  Moved down from ShikkiPluginAPI on 2026-11-15 and converted from
//  `final class … @unchecked Sendable` + `NSLock` to a plain `actor`.
//
//  WHY THE CONVERSION, not a defence of the lock: the lock existed only
//  because `subscribe` and `intercept` were synchronous protocol
//  requirements, and an actor cannot be reached without an `await`. The
//  fleet rule `unchecked-sendable-on-a-recorder-is-a-symptom-make-the-callback-async`
//  gives the ladder — return the value, else async protocol -> actor, else
//  shared double — and `Synchronization.Mutex` is unavailable at CoreKit's
//  macOS 14 floor (it needs macOS 15). So the two requirements became
//  `async` and every line of synchronisation code went away: no `NSLock`,
//  no `@unchecked Sendable`, no lock-scoped helper layer, no hand-written
//  snapshot to avoid a torn read. The compiler now proves what the comment
//  used to assert.
//
//  State is actor-isolated, indexed by topic, and filtered by event type at
//  publish time via `ObjectIdentifier(E.self)`. Subscribers unregister when
//  their `AsyncStream` terminates; interceptors unregister when their
//  ``DisposerToken`` is disposed (BR-DI-11).
//

import Foundation

/// A single-process, Foundation-only event bus.
///
/// Zero third-party dependencies — suitable as the default DI slot for
/// projects that need pub/sub semantics but not cross-process transport.
/// For cross-process delivery, use a bus backed by a real transport that
/// lives in a downstream package.
///
/// ## Concurrency
///
/// An `actor`. Registration state is actor-isolated, so there is no lock
/// and no `@unchecked Sendable`: multiple publishers and subscribers may
/// share one instance across concurrency domains and the compiler checks
/// it. Awaiting ``subscribe(_:topic:)`` or ``intercept(_:topic:_:)``
/// guarantees the registration is in place when the call returns.
///
/// ## Mode support
///
/// - ``DispatchMode/emit`` — notifies subscribers without awaiting them.
/// - ``DispatchMode/serial`` — notifies subscribers in registration order.
/// - ``DispatchMode/parallel`` — notifies subscribers concurrently and
///   awaits every notification before `publish` returns.
/// - ``DispatchMode/waterfall`` — threads the event through registered
///   interceptors; each may short-circuit by returning without calling
///   `next`. Interceptors wrap in registration order (first is outermost).
///
/// All four modes are honoured, so this bus never throws
/// ``EventBusError/unsupportedMode(_:)`` — a bus that could not honour a
/// mode would have to (BR-DI-12).
public actor InMemoryEventBusProvider: EventBusProviding {

    // MARK: State

    /// Type-erased subscriber entry. The `yield` closure captures the
    /// concrete `AsyncStream<E>.Continuation` and performs the `Any -> E`
    /// cast internally, so the bus can index all subscribers uniformly.
    private struct SubscriberEntry: Sendable {
        let id: UUID
        let typeID: ObjectIdentifier
        let yield: @Sendable (Any) -> Void
    }

    /// Type-erased interceptor entry. The `handler` is the middleware
    /// body wrapped so it accepts `Any` and receives an `Any`-typed
    /// `next` closure that internally re-casts to `E`.
    private struct InterceptorEntry: Sendable {
        let id: UUID
        let typeID: ObjectIdentifier
        let handler: @Sendable (Any, @Sendable (Any) async throws -> Any) async throws -> Any
    }

    private var subscribers: [String: [SubscriberEntry]] = [:]
    private var interceptors: [String: [InterceptorEntry]] = [:]

    // MARK: Init

    public init() {}

    // MARK: EventBusProviding

    public func publish<E: Sendable>(_ event: E, topic: String, mode: DispatchMode) async throws {
        let typeID = ObjectIdentifier(E.self)
        let matchingSubs = (subscribers[topic] ?? []).filter { $0.typeID == typeID }
        let matchingInterceptors = (interceptors[topic] ?? []).filter { $0.typeID == typeID }

        switch mode {
        case .emit:
            // Fire-and-forget: notify subscribers, don't await anything.
            for sub in matchingSubs {
                sub.yield(event)
            }

        case .serial:
            // Notify subscribers one after the other, in registration
            // order. `yield` on an `AsyncStream.Continuation` is
            // non-blocking and thread-safe; ordering across subscribers
            // is preserved by iterating in sequence.
            for sub in matchingSubs {
                sub.yield(event)
            }

        case .parallel:
            // Notify subscribers concurrently and await every
            // notification before returning.
            await withTaskGroup(of: Void.self) { group in
                for sub in matchingSubs {
                    group.addTask {
                        sub.yield(event)
                    }
                }
            }

        case .waterfall:
            // Compose the interceptor chain. Outermost = first
            // registered; innermost `next` is the identity function so
            // that an interceptor calling `next(event)` at the tail
            // simply returns the (possibly transformed) event.
            var next: @Sendable (Any) async throws -> Any = { $0 }
            for interceptor in matchingInterceptors.reversed() {
                let prevNext = next
                let handler = interceptor.handler
                next = { anyEvent in
                    try await handler(anyEvent, prevNext)
                }
            }
            _ = try await next(event)
        }
    }

    public func subscribe<E: Sendable>(_: E.Type, topic: String) async -> AsyncStream<E> {
        let typeID = ObjectIdentifier(E.self)
        let id = UUID()

        var captured: AsyncStream<E>.Continuation?
        let stream = AsyncStream<E> { continuation in
            captured = continuation
        }
        guard let continuation = captured else {
            // `AsyncStream`'s builder runs synchronously during init, so
            // this is unreachable. Returning the stream rather than
            // force-unwrapping keeps an unreachable branch from becoming
            // a crash.
            return stream
        }

        let yield: @Sendable (Any) -> Void = { anyEvent in
            if let typed = anyEvent as? E {
                continuation.yield(typed)
            }
        }

        // Registered on the actor's own isolation, BEFORE the stream is
        // handed back — so a publish issued after this call returns
        // cannot be missed.
        subscribers[topic, default: []].append(
            SubscriberEntry(id: id, typeID: typeID, yield: yield)
        )

        // Cancellation / consumer drop -> unregister (BR-DI-11). The
        // handler is non-async, so it hops onto the actor.
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id: id, topic: topic) }
        }

        return stream
    }

    public func intercept<E: Sendable>(
        _: E.Type,
        topic: String,
        _ body: @escaping @Sendable (E, _ next: @Sendable (E) async throws -> E) async throws -> E
    ) async -> DisposerToken {
        let typeID = ObjectIdentifier(E.self)
        let id = UUID()

        // Wrap the typed body so it fits the erased `(Any, (Any)->Any)`
        // slot the bus stores. The `next` closure the body receives is
        // typed as `(E) -> E`; internally it re-erases to call the erased
        // downstream chain.
        let handler: @Sendable (Any, @Sendable (Any) async throws -> Any) async throws -> Any = { anyEvent, erasedNext in
            guard let typed = anyEvent as? E else {
                // Type didn't match — pass through untouched. Should not
                // happen because `publish` filters by `typeID`, but be
                // defensive.
                return try await erasedNext(anyEvent)
            }
            let typedNext: @Sendable (E) async throws -> E = { nextEvent in
                let result = try await erasedNext(nextEvent)
                return (result as? E) ?? nextEvent
            }
            return try await body(typed, typedNext)
        }

        interceptors[topic, default: []].append(
            InterceptorEntry(id: id, typeID: typeID, handler: handler)
        )

        return DisposerToken { [weak self] in
            await self?.removeInterceptor(id: id, topic: topic)
        }
    }

    // MARK: Actor-isolated teardown

    private func removeSubscriber(id: UUID, topic: String) {
        subscribers[topic]?.removeAll { $0.id == id }
    }

    private func removeInterceptor(id: UUID, topic: String) {
        interceptors[topic]?.removeAll { $0.id == id }
    }

    // MARK: Introspection (tests)

    /// Number of registered subscribers on `topic`, for tests that assert
    /// reversibility (BR-DI-11) rather than inferring it from behaviour.
    public func subscriberCount(topic: String) -> Int {
        subscribers[topic]?.count ?? 0
    }

    /// Number of registered interceptors on `topic`, for tests that assert
    /// reversibility (BR-DI-11) rather than inferring it from behaviour.
    public func interceptorCount(topic: String) -> Int {
        interceptors[topic]?.count ?? 0
    }
}
