//
//  CoreKitEventBusAssemblyTests.swift
//  CoreKitTests
//
//  The bus is reached through the DI container (spec c8fa126c rev 2,
//  BR-L-03/BR-L-06). These tests assert the registration, the environment
//  split, and that a MISSING registration is a named failure rather than a
//  nil that degrades into a dropped event.
//

import Foundation
import Testing

@testable import CoreKit

@Suite("CoreKitEventBusAssembly — the bus comes from the container")
struct CoreKitEventBusAssemblyTests {

    struct Ping: Sendable, Equatable {
        let n: Int
    }

    @Test("production registers the in-memory bus, and it round-trips")
    func productionRegistersInMemoryBus() async throws {
        let container = Container(name: "EventBusAssemblyTests.production")
        CoreKitEventBusAssembly().assemble(container: container, environment: .production)

        let bus = try container.resolve((any EventBusProviding).self)
        #expect(bus is InMemoryEventBusProvider)

        let stream = await bus.subscribe(Ping.self, topic: "di.roundtrip")
        try await bus.publish(Ping(n: 7), topic: "di.roundtrip", mode: .emit)

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == Ping(n: 7))
    }

    @Test("mock registers the no-op bus, which drops events by design")
    func mockRegistersNoOpBus() async throws {
        let container = Container(name: "EventBusAssemblyTests.mock")
        CoreKitEventBusAssembly().assemble(container: container, environment: .mock)

        let bus = try container.resolve((any EventBusProviding).self)
        #expect(bus is NoOpEventBusProvider)

        let stream = await bus.subscribe(Ping.self, topic: "di.dropped")
        try await bus.publish(Ping(n: 1), topic: "di.dropped", mode: .emit)

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test("the slot is .cached, so one container hands out one bus")
    func busIsCachedPerContainer() throws {
        let container = Container(name: "EventBusAssemblyTests.cached")
        CoreKitEventBusAssembly().assemble(container: container, environment: .production)

        let first = try container.resolve((any EventBusProviding).self)
        let second = try container.resolve((any EventBusProviding).self)

        // Two instances would not see each other's subscribers, which is a
        // silent delivery failure rather than an error — so identity matters.
        let a = first as? InMemoryEventBusProvider
        let b = second as? InMemoryEventBusProvider
        #expect(a != nil)
        #expect(a === b)
    }

    @Test("resolving without the assembly is a named error, never a nil default")
    func missingRegistrationIsNamed() throws {
        let container = Container(name: "EventBusAssemblyTests.unregistered")
        // Assembly deliberately NOT applied.
        #expect(throws: ContainerError.self) {
            _ = try container.resolve((any EventBusProviding).self)
        }
    }

    @Test("DI.configure wires the slot through the public entry point")
    func diConfigureWiresTheSlot() async throws {
        let container = DI.configure(for: .production, assemblies: [CoreKitEventBusAssembly()])
        let bus = try container.resolve((any EventBusProviding).self)

        let stream = await bus.subscribe(Ping.self, topic: "di.configure")
        try await bus.publish(Ping(n: 42), topic: "di.configure", mode: .parallel)

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == Ping(n: 42))
    }
}
