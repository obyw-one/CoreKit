//
//  EventBusProvidingTests.swift
//  CoreKitTests
//
//  Ported from ShikkiPluginAPITests on 2026-11-15 with the move of
//  EventBusProviding down to CoreKit. Two deliberate changes:
//
//  1. `subscribe` / `intercept` are now `async`, so every call site awaits.
//     That is what lets the provider be an `actor` with no lock.
//  2. `subscribeCancellationUnregisters` and
//     `disposerUnregistersInReverseOrder` now ASSERT THE REGISTRATION COUNT.
//     The original test said so itself — "We can't assert absence directly
//     without exposing internals" — and then published an event and asserted
//     nothing, which is a test that cannot fail. The actor exposes
//     `subscriberCount(topic:)` / `interceptorCount(topic:)` so the
//     reversibility rule (BR-DI-11) is measured rather than implied.
//
//  Named cases carried over unchanged:
//    inMemoryPubSubRoundTrips, noOpDropsAll, serialAccumulatesInOrder,
//    parallelAwaitsAll, waterfallShortCircuits,
//    waterfallWrapsInRegistrationOrder, disposerUnregistersInReverseOrder
//

import Foundation
import Testing

@testable import CoreKit

@Suite("EventBusProviding — DispatchMode + reversibility")
struct EventBusProvidingTests {

    // MARK: Fixtures

    struct StringEvent: Sendable, Equatable {
        let payload: String
    }

    /// Small ordered-log actor so tests can assert observable dispatch
    /// order without dragging in a logging dep (BR-DI-01).
    actor CallLog {
        private(set) var entries: [String] = []
        func append(_ entry: String) { entries.append(entry) }
        var snapshot: [String] { entries }
    }

    // MARK: - inMemoryPubSubRoundTrips

    @Test("InMemory: publish → subscribe round-trips a single event")
    func inMemoryPubSubRoundTrips() async throws {
        let bus = InMemoryEventBusProvider()
        let stream = await bus.subscribe(StringEvent.self, topic: "auth.login")

        let expected = StringEvent(payload: "hello")
        try await bus.publish(expected, topic: "auth.login", mode: .emit)

        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received == expected)
    }

    // MARK: - noOpDropsAll

    @Test("NoOp: publish is dropped; subscribe stream is already finished")
    func noOpDropsAll() async throws {
        let bus = NoOpEventBusProvider()
        let stream = await bus.subscribe(StringEvent.self, topic: "auth.login")

        // Publish across every mode — noop honours all four trivially.
        for mode in DispatchMode.allCases {
            try await bus.publish(StringEvent(payload: "x"), topic: "auth.login", mode: mode)
        }

        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received == nil)
    }

    // MARK: - serialAccumulatesInOrder

    @Test("Serial: subscribers receive events in registration order")
    func serialAccumulatesInOrder() async throws {
        let bus = InMemoryEventBusProvider()
        let stream1 = await bus.subscribe(StringEvent.self, topic: "flow.step")
        let stream2 = await bus.subscribe(StringEvent.self, topic: "flow.step")
        let stream3 = await bus.subscribe(StringEvent.self, topic: "flow.step")

        try await bus.publish(StringEvent(payload: "one"), topic: "flow.step", mode: .serial)
        try await bus.publish(StringEvent(payload: "two"), topic: "flow.step", mode: .serial)

        // Each subscriber receives both events in publish order.
        var i1 = stream1.makeAsyncIterator()
        var i2 = stream2.makeAsyncIterator()
        var i3 = stream3.makeAsyncIterator()

        let r1a = await i1.next()
        let r1b = await i1.next()
        let r2a = await i2.next()
        let r2b = await i2.next()
        let r3a = await i3.next()
        let r3b = await i3.next()

        #expect(r1a?.payload == "one")
        #expect(r1b?.payload == "two")
        #expect(r2a?.payload == "one")
        #expect(r2b?.payload == "two")
        #expect(r3a?.payload == "one")
        #expect(r3b?.payload == "two")
    }

    // MARK: - parallelAwaitsAll

    @Test("Parallel: publish delivers to every subscriber")
    func parallelAwaitsAll() async throws {
        let bus = InMemoryEventBusProvider()
        let stream1 = await bus.subscribe(StringEvent.self, topic: "fanout")
        let stream2 = await bus.subscribe(StringEvent.self, topic: "fanout")
        let stream3 = await bus.subscribe(StringEvent.self, topic: "fanout")

        try await bus.publish(StringEvent(payload: "boom"), topic: "fanout", mode: .parallel)

        var i1 = stream1.makeAsyncIterator()
        var i2 = stream2.makeAsyncIterator()
        var i3 = stream3.makeAsyncIterator()

        let r1 = await i1.next()
        let r2 = await i2.next()
        let r3 = await i3.next()

        #expect(r1?.payload == "boom")
        #expect(r2?.payload == "boom")
        #expect(r3?.payload == "boom")
    }

    // MARK: - waterfallShortCircuits

    @Test("Waterfall: an interceptor that omits `next` short-circuits the chain")
    func waterfallShortCircuits() async throws {
        let bus = InMemoryEventBusProvider()
        let log = CallLog()

        // First registered = outermost. It runs its body but does NOT
        // call `next`, so the second interceptor MUST NOT fire.
        let outer = await bus.intercept(StringEvent.self, topic: "mid") { event, _ in
            await log.append("outer")
            return event
        }
        let inner = await bus.intercept(StringEvent.self, topic: "mid") { event, next in
            await log.append("inner")
            return try await next(event)
        }

        try await bus.publish(StringEvent(payload: "x"), topic: "mid", mode: .waterfall)

        let entries = await log.snapshot
        #expect(entries == ["outer"])

        await outer.dispose()
        await inner.dispose()
    }

    // MARK: - waterfallWrapsInRegistrationOrder

    @Test("Waterfall: interceptors wrap in registration order (first = outermost)")
    func waterfallWrapsInRegistrationOrder() async throws {
        let bus = InMemoryEventBusProvider()
        let log = CallLog()

        let d1 = await bus.intercept(StringEvent.self, topic: "wrap") { event, next in
            await log.append("before1")
            let result = try await next(event)
            await log.append("after1")
            return result
        }
        let d2 = await bus.intercept(StringEvent.self, topic: "wrap") { event, next in
            await log.append("before2")
            let result = try await next(event)
            await log.append("after2")
            return result
        }

        try await bus.publish(StringEvent(payload: "x"), topic: "wrap", mode: .waterfall)

        let entries = await log.snapshot
        #expect(entries == ["before1", "before2", "after2", "after1"])

        await d1.dispose()
        await d2.dispose()
    }

    // MARK: - disposerUnregistersInReverseOrder

    @Test("Disposer: reverse-order disposal removes every interceptor")
    func disposerUnregistersInReverseOrder() async throws {
        let bus = InMemoryEventBusProvider()
        let log = CallLog()

        let d1 = await bus.intercept(StringEvent.self, topic: "tear") { event, next in
            await log.append("i1")
            return try await next(event)
        }
        let d2 = await bus.intercept(StringEvent.self, topic: "tear") { event, next in
            await log.append("i2")
            return try await next(event)
        }
        let d3 = await bus.intercept(StringEvent.self, topic: "tear") { event, next in
            await log.append("i3")
            return try await next(event)
        }

        #expect(await bus.interceptorCount(topic: "tear") == 3)

        // Sanity: with all three registered the chain fires in order.
        try await bus.publish(StringEvent(payload: "x"), topic: "tear", mode: .waterfall)
        let afterRegister = await log.snapshot
        #expect(afterRegister == ["i1", "i2", "i3"])

        // Tear down in REVERSE registration order per BR-DI-11.
        await d3.dispose()
        #expect(await bus.interceptorCount(topic: "tear") == 2)
        await d2.dispose()
        #expect(await bus.interceptorCount(topic: "tear") == 1)
        await d1.dispose()
        #expect(await bus.interceptorCount(topic: "tear") == 0)

        // No interceptors left → no additional entries appended.
        try await bus.publish(StringEvent(payload: "x"), topic: "tear", mode: .waterfall)
        let afterDispose = await log.snapshot
        #expect(afterDispose == ["i1", "i2", "i3"])
    }

    // MARK: - Disposing twice is a no-op

    @Test("Disposer: disposing the same token twice does not under-count")
    func disposeIsIdempotent() async throws {
        let bus = InMemoryEventBusProvider()
        let a = await bus.intercept(StringEvent.self, topic: "twice") { event, next in
            try await next(event)
        }
        let b = await bus.intercept(StringEvent.self, topic: "twice") { event, next in
            try await next(event)
        }
        #expect(await bus.interceptorCount(topic: "twice") == 2)

        await a.dispose()
        await a.dispose()
        // The second dispose must not remove `b`.
        #expect(await bus.interceptorCount(topic: "twice") == 1)

        await b.dispose()
        #expect(await bus.interceptorCount(topic: "twice") == 0)
    }

    // MARK: - Type-filter safety net

    @Test("InMemory: subscribers of a different type on the same topic are not delivered")
    func inMemoryFiltersByEventType() async throws {
        struct OtherEvent: Sendable, Equatable {
            let n: Int
        }
        let bus = InMemoryEventBusProvider()
        let stringStream = await bus.subscribe(StringEvent.self, topic: "shared")
        let intStream = await bus.subscribe(OtherEvent.self, topic: "shared")

        try await bus.publish(StringEvent(payload: "only-string"), topic: "shared", mode: .parallel)

        var stringIter = stringStream.makeAsyncIterator()
        let s = await stringIter.next()
        #expect(s?.payload == "only-string")

        // The int subscriber must NOT have observed the string event: the
        // next value it sees is the int published after it.
        var intIter = intStream.makeAsyncIterator()
        try await bus.publish(OtherEvent(n: 42), topic: "shared", mode: .parallel)
        let i = await intIter.next()
        #expect(i?.n == 42)
    }

    // MARK: - Subscribe cancellation unregisters

    @Test("Subscribe: terminating the stream unregisters the subscriber (BR-DI-11)")
    func subscribeCancellationUnregisters() async throws {
        let bus = InMemoryEventBusProvider()

        do {
            let stream = await bus.subscribe(StringEvent.self, topic: "leak")
            var iterator = stream.makeAsyncIterator()
            #expect(await bus.subscriberCount(topic: "leak") == 1)
            try await bus.publish(StringEvent(payload: "before-cancel"), topic: "leak", mode: .emit)
            _ = await iterator.next()
            // Iterator (and underlying stream) drops on scope exit here.
        }

        // `onTermination` hops onto the actor, so poll the count rather
        // than sleeping a fixed interval and hoping.
        var observed = await bus.subscriberCount(topic: "leak")
        for _ in 0..<100 where observed != 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
            observed = await bus.subscriberCount(topic: "leak")
        }
        #expect(observed == 0)

        // And publishing afterwards stays safe.
        try await bus.publish(StringEvent(payload: "after-cancel"), topic: "leak", mode: .emit)
    }

    // MARK: - Registration is in place when `subscribe` returns

    @Test("Subscribe: an event published after the await cannot be missed")
    func subscribeIsRegisteredWhenItReturns() async throws {
        let bus = InMemoryEventBusProvider()
        let stream = await bus.subscribe(StringEvent.self, topic: "ordered")
        // No sleep, no yield: awaiting subscribe is the guarantee.
        try await bus.publish(StringEvent(payload: "first"), topic: "ordered", mode: .emit)

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.payload == "first")
    }
}
