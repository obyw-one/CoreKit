//
//  CoreKitEventBusAssembly.swift
//  CoreKit
//
//  The event bus is reached through the DI container, never through a
//  `.shared` singleton (BR-DI-05) and never by a consumer naming a concrete
//  type. Spec c8fa126c rev 2, BR-L-02/BR-L-03: a capability is one protocol
//  in the portable target, and the choice of implementation is made in an
//  assembly.
//
//  Unlike logging or reachability, the bus needs NO `#if` — it is
//  Foundation-only and identical on every target, so the axis here is the
//  ENVIRONMENT (production vs mock), which is the axis `DIAssembly` already
//  has. There is no platform assembly for this slot and there must not be
//  one: a condition where none is needed is exactly the drift BR-L-04 bans.
//

import Foundation

/// Registers the ``EventBusProviding`` slot.
///
/// - `.production` gets ``InMemoryEventBusProvider`` — the real
///   single-process bus.
/// - `.mock` gets ``NoOpEventBusProvider``, which drops every event
///   (`noop-provider-swallow`, BR-DI-10). A test that needs to observe
///   dispatch registers ``InMemoryEventBusProvider`` itself, or its own
///   double, rather than relying on the mock environment.
///
/// Registered `.cached`, the container's default scope, so one process has
/// one bus: two instances would not see each other's subscribers, which is a
/// silent delivery failure rather than an error.
///
/// ```swift
/// let container = DI.configure(for: .production, assemblies: [
///     CoreKitEventBusAssembly(),
/// ])
/// let bus: any EventBusProviding = container.require((any EventBusProviding).self)
/// ```
///
/// A consumer that resolves this slot without registering the assembly gets
/// `ContainerError.notRegistered` — a named failure at the composition root,
/// not a `nil` that degrades into a dropped event (BR-L-06).
public struct CoreKitEventBusAssembly: DIAssembly {

    public init() {}

    public func assemble(container: Container, environment: DIEnvironment) {
        switch environment {
        case .production:
            container.register((any EventBusProviding).self) { _ in
                InMemoryEventBusProvider()
            }
        case .mock:
            container.register((any EventBusProviding).self) { _ in
                NoOpEventBusProvider()
            }
        }
    }
}
