//
//  NoOpEventBusProvider.swift
//  CoreKit
//
//  Moved down from ShikkiPluginAPI on 2026-11-15.
//
//  BR-DI-02: every DI slot ships a `NoOp*` peer for tests / disabled
//            features.
//  BR-DI-10: silent-fail is documented — this provider drops all events on
//            purpose (`noop-provider-swallow`). Shipping it in production is
//            a config error, not a bug.
//
//  Waterfall on the no-op is the IDENTITY chain: with no interceptors, the
//  event is threaded through `{ $0 }` and returned unchanged.
//

import Foundation

/// A `NoOp` implementation of ``EventBusProviding`` for tests and
/// features that are intentionally disabled.
///
/// - `publish` accepts every ``DispatchMode`` without throwing — the
///   no-op chain is the identity chain and honours all four modes
///   trivially.
/// - `subscribe` returns an already-finished stream — iterators receive
///   `nil` immediately.
/// - `intercept` returns a ``DisposerToken`` whose `dispose()` is a no-op.
///
/// It stays a `struct` with no state, so it needs no isolation of any kind.
///
/// > Warning: Shipping this in production silently drops every event
///   (`noop-provider-swallow`). Suitable for **tests only** or for
///   explicitly disabled features.
public struct NoOpEventBusProvider: EventBusProviding {

    public init() {}

    /// Drop `event` unconditionally. Never throws — every
    /// ``DispatchMode`` is honoured trivially (the no-op chain is the
    /// identity chain).
    public func publish<E: Sendable>(_: E, topic _: String, mode _: DispatchMode) async throws {
        // Intentionally empty. BR-DI-10: silent-fail is documented in the
        // type doc above.
    }

    /// Return an already-finished `AsyncStream` — iterators immediately
    /// receive `nil`.
    public func subscribe<E: Sendable>(_: E.Type, topic _: String) async -> AsyncStream<E> {
        AsyncStream<E> { continuation in
            continuation.finish()
        }
    }

    /// Return a ``DisposerToken`` whose `dispose()` is a no-op — the
    /// no-op bus has no registration state to unregister.
    public func intercept<E: Sendable>(
        _: E.Type,
        topic _: String,
        _: @escaping @Sendable (E, _ next: @Sendable (E) async throws -> E) async throws -> E
    ) async -> DisposerToken {
        DisposerToken {}
    }
}
