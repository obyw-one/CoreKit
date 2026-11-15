//
//  DispatchMode.swift
//  CoreKit
//
//  Moved down from ShikkiPluginAPI (DI/EventBus) on 2026-11-15 by operator
//  ruling: the fleet's Combine replacement belongs in the lowest layer, so
//  CoreKit consumers can reach it without inverting the dependency direction.
//  Name unchanged by standing ruling (memory rule
//  `eventbusproviding-is-the-linux-combine-replacement-seed-keep-rename-first-consumer`).
//
//  BR-DI-12 (dispatch-mode-is-contract): an event's dispatch semantics are
//  part of the EVENT CONTRACT — declared per publish — not an implementation
//  detail. A bus that cannot honour a mode MUST throw, never silently
//  degrade to `.emit`.
//

import Foundation

/// How a published event is dispatched to its subscribers / interceptors.
///
/// Chosen by the publisher on each call to
/// ``EventBusProviding/publish(_:topic:mode:)`` — the mode is part of the
/// event contract, not a runtime knob on the bus.
///
/// Semantics per case:
///
/// - ``emit`` — fire-and-forget. `publish` returns as soon as the event has
///   been handed to the bus; subscribers are notified asynchronously and
///   the publisher does not wait for them.
/// - ``serial`` — every subscriber matching the topic (and event type) is
///   notified in registration order; ordering is guaranteed.
/// - ``parallel`` — every matching subscriber is notified concurrently and
///   `publish` awaits until each notification has been delivered.
/// - ``waterfall`` — the event is threaded through the registered
///   interceptors (see ``EventBusProviding/intercept(_:topic:_:)``) as a
///   middleware chain. An interceptor that returns without calling `next`
///   short-circuits the chain.
///
/// - Important: A conforming bus that cannot honour a mode MUST throw
///   (typically an ``EventBusError/unsupportedMode(_:)``) rather than
///   silently degrading — BR-DI-12.
public enum DispatchMode: String, Sendable, CaseIterable, Equatable {
    /// Fire-and-forget — `publish` does not await subscribers.
    case emit
    /// Notify subscribers one after the other, in registration order.
    case serial
    /// Notify subscribers concurrently; `publish` awaits all of them.
    case parallel
    /// Run interceptors as a middleware chain; each may short-circuit.
    case waterfall
}
