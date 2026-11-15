//
//  EventBusProviding.swift
//  CoreKit
//
//  Moved down from ShikkiPluginAPI (DI/EventBus) on 2026-11-15 by operator
//  ruling. The name does not change.
//
//  BR-DI-01: zero-dep — Foundation only, so the contract builds for every
//            target CoreKit supports, Linux included.
//  BR-DI-03: Sendable protocol.
//  BR-DI-04: public — cross-package consumption.
//  BR-DI-05: init-injection only; no `.shared` singletons.
//  BR-DI-11 (reversibility): every registration returns a means of teardown
//            (an `AsyncStream` whose cancellation unregisters, or a
//            ``DisposerToken`` whose `dispose()` unregisters). Teardown order
//            is documented as REVERSE of install order.
//  BR-DI-12 (dispatch-mode-is-contract): a bus that cannot honour a mode
//            MUST throw — never silently degrade to `.emit`.
//
//  CHANGED IN THE MOVE — `subscribe` and `intercept` are now `async`.
//  In ShikkiPluginAPI both were synchronous, which is the only reason
//  ``InMemoryEventBusProvider`` was a `final class … @unchecked Sendable`
//  with an `NSLock`: an actor cannot be reached without an `await`. Per the
//  fleet rule `unchecked-sendable-on-a-recorder-is-a-symptom-make-the-callback-async`
//  the ladder is "return the value, else async protocol -> actor, else shared
//  double", and `Synchronization.Mutex` is not an option here because it needs
//  macOS 15 while CoreKit's floor is macOS 14. Making the two requirements
//  `async` turns the provider into a plain `actor` with no synchronisation
//  code and no `@unchecked` anywhere. Measured at the time of the move: ZERO
//  consumers fleet-wide, so the signature change breaks nothing.
//

import Foundation

// MARK: - EventBusError

/// Errors thrown by ``EventBusProviding`` implementations.
///
/// - Note: This is deliberately narrow — implementations layer their own
///   backend-specific errors on top. The only universal contract failures
///   the protocol itself can produce are captured here.
public enum EventBusError: Error, Sendable, Equatable {
    /// The bus implementation cannot honour the requested
    /// ``DispatchMode``. Per BR-DI-12 an unsupported mode MUST throw
    /// rather than degrade silently.
    case unsupportedMode(DispatchMode)
}

// MARK: - DisposerToken

/// Sendable handle returned by registration-style APIs on
/// ``EventBusProviding`` (currently ``EventBusProviding/intercept(_:topic:_:)``)
/// per BR-DI-11.
///
/// Calling ``dispose()`` unregisters the associated effect. Dropping a
/// token without calling `dispose()` leaks the registration — that is the
/// in-process twin of the orphan-subprocess class (`disposer-never-called`).
/// Adopters SHOULD hold a disposer for every registration they perform and
/// dispose them in REVERSE registration order at teardown.
///
/// The token is safe to pass across concurrency domains and safe to
/// dispose more than once — subsequent disposes are no-ops.
public struct DisposerToken: Sendable {

    private let _dispose: @Sendable () async -> Void

    /// Create a token from a `@Sendable` teardown closure.
    ///
    /// The closure MUST be safe to invoke more than once (typically by
    /// idempotent removal — e.g. `removeAll { $0.id == id }`).
    public init(_ dispose: @escaping @Sendable () async -> Void) {
        _dispose = dispose
    }

    /// Unregister the effect that returned this token.
    ///
    /// Safe to call more than once; subsequent calls are no-ops.
    public func dispose() async {
        await _dispose()
    }
}

// MARK: - EventBusProviding

/// A Foundation-only, zero-dep in-process event bus — the fleet's
/// reactive seam and its Combine replacement on platforms that have no
/// Combine.
///
/// This is the SHAPE. Implementations live either here
/// (``InMemoryEventBusProvider`` / ``NoOpEventBusProvider``) or in
/// downstream packages that can bring heavier dependencies (a NATS-backed
/// bus in ShikkiCore, for example).
///
/// - Important: NATS is NATS and is never called an event bus. This slot is
///   the in-process bus; the distributed bus is a transport and has its own
///   seam.
///
/// ## Dispatch modes
///
/// The publisher chooses semantics per call via ``DispatchMode``:
///
/// ```swift
/// try await bus.publish(event, topic: "auth.login", mode: .parallel)
/// ```
///
/// A conforming bus MUST throw ``EventBusError/unsupportedMode(_:)`` for
/// any mode it cannot honour — BR-DI-12.
///
/// ## Subscribe
///
/// Subscription is expressed as an `AsyncStream` whose cancellation
/// unregisters the subscriber — BR-DI-11 (reversibility). The standard
/// idiom:
///
/// ```swift
/// let stream = await bus.subscribe(LoginEvent.self, topic: "auth.login")
/// for await event in stream {
///     handle(event)
/// }
/// // Terminating the loop (or dropping the stream) unregisters.
/// ```
///
/// ## Waterfall (middleware) — intercept
///
/// For waterfall dispatch, register interceptors with
/// ``intercept(_:topic:_:)``. The body receives the event and a `next`
/// closure — call `next(event)` to delegate to the next interceptor,
/// return without calling `next` to short-circuit. Interceptors wrap in
/// REGISTRATION order (first registered is outermost). The returned
/// ``DisposerToken`` unregisters when disposed.
///
/// ## Substitution recipe (BR-DI-09)
///
/// ```swift
/// struct FakeEventBus: EventBusProviding {
///     func publish<E: Sendable>(_ event: E, topic: String, mode: DispatchMode) async throws {}
///     func subscribe<E: Sendable>(_ type: E.Type, topic: String) async -> AsyncStream<E> {
///         AsyncStream { $0.finish() }
///     }
///     func intercept<E: Sendable>(
///         _ type: E.Type,
///         topic: String,
///         _ body: @escaping @Sendable (E, _ next: @Sendable (E) async throws -> E) async throws -> E
///     ) async -> DisposerToken { DisposerToken { } }
/// }
/// ```
public protocol EventBusProviding: Sendable {

    /// Publish `event` on `topic` using the requested `mode`.
    ///
    /// - Parameters:
    ///   - event: The event value. Must be `Sendable` — events cross
    ///     concurrency domains.
    ///   - topic: A string routing key. Convention is dot-separated
    ///     (`"auth.login"`, `"flow.progress"`) but the bus treats topic
    ///     as an opaque token.
    ///   - mode: Dispatch semantics per ``DispatchMode``.
    /// - Throws: ``EventBusError/unsupportedMode(_:)`` if the bus cannot
    ///   honour `mode` (BR-DI-12). Implementations MAY throw
    ///   backend-specific errors too.
    func publish<E: Sendable>(_ event: E, topic: String, mode: DispatchMode) async throws

    /// Subscribe to events of type `E` on `topic`.
    ///
    /// The returned `AsyncStream` yields every event whose type matches
    /// `E` and whose topic matches. Consuming the stream to completion
    /// (or dropping it) unregisters the subscriber per BR-DI-11.
    ///
    /// - Note: `async` so that an `actor`-backed bus can register the
    ///   subscriber on its own isolation before the stream is returned —
    ///   which is what lets the shipped implementation hold no lock.
    ///   Awaiting the call guarantees the subscriber is registered when it
    ///   returns, so a publish issued after it cannot be missed.
    ///
    /// - Parameters:
    ///   - type: The event type to filter on. Events of other types
    ///     published on the same topic are silently ignored.
    ///   - topic: The topic to subscribe to.
    /// - Returns: An `AsyncStream<E>` whose termination unregisters.
    func subscribe<E: Sendable>(_ type: E.Type, topic: String) async -> AsyncStream<E>

    /// Register a waterfall interceptor for events of type `E` on
    /// `topic`.
    ///
    /// The interceptor is a middleware: it receives the event and a
    /// `next` closure. To delegate to the next interceptor in the chain,
    /// call `try await next(event)` (optionally with a mutated event).
    /// To short-circuit the chain, return without calling `next`.
    ///
    /// Interceptors wrap in REGISTRATION order — the first-registered
    /// interceptor is outermost and runs before its inner interceptors,
    /// and after them on the way back up.
    ///
    /// - Note: `async` for the same reason as ``subscribe(_:topic:)``, and
    ///   with a stronger consequence: awaiting the call is what makes
    ///   "interceptors wrap in registration order" a guarantee rather than
    ///   a race between two deferred registrations.
    ///
    /// - Parameters:
    ///   - type: The event type to intercept.
    ///   - topic: The topic to intercept on.
    ///   - body: `@Sendable` middleware body.
    /// - Returns: A ``DisposerToken`` — call `dispose()` in REVERSE
    ///   registration order at teardown (BR-DI-11).
    func intercept<E: Sendable>(
        _ type: E.Type,
        topic: String,
        _ body: @escaping @Sendable (E, _ next: @Sendable (E) async throws -> E) async throws -> E
    ) async -> DisposerToken
}
