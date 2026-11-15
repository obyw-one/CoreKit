//
//  CoreKitPlatformAssembly.swift
//  CoreKit
//
//  Spec c8fa126c, BR-L-03 and BR-L-04. THE one place in CoreKit where the
//  compilation target is named.
//
//  The operator's ruling, 2026-11-15: *"we have to make those SPMs
//  Linux-compatible, not prevent their import. `os` is used mainly for logging;
//  we already addressed this. It must be managed from the DI container and
//  registration, to get the correct component for the current compilation
//  target."* This file is that registration.
//
//  Why the conditions are HERE and nowhere else: a condition at a call site
//  means every shared call site grows one, and the two arms drift because no
//  single test can see both. A condition in a DI assembly is a choice made once,
//  at the composition root, whose job is choosing. The BR-L-04 ratchet
//  (`CorePortabilityRatchetTests`) is what keeps it to one place, and it
//  excludes `Sources/CoreKit/Platform/` BY PATH — the subtree, not a filename
//  list ([[a-ratchet-scopes-a-folder-subtree-never-a-filename-list]]).
//

import Foundation

/// Registers every CoreKit capability whose implementation depends on the
/// compilation target.
///
/// | capability | Apple | elsewhere |
/// |---|---|---|
/// | ``LoggingProviding`` | ``OSLogLogger`` (`os.Logger`) | ``SwiftLogLogger`` (swift-log) |
/// | ``ReachabilityProviding`` | ``NWPathReachability`` (`NWPathMonitor`) | ``GetifaddrsReachability`` (`getifaddrs(3)`) |
/// | ``DeviceCapacityProbing`` | ``PlatformCapacityProber`` (`sysctl`, Metal) | ``ProcMeminfoCapacityProber`` (`/proc/meminfo`) |
///
/// Usage:
/// ```swift
/// let container = DI.configure(for: .production, assemblies: [
///     CoreKitPlatformAssembly(),
///     CoreKitEventBusAssembly(),
/// ])
/// let log = container.require((any LoggingProviding).self)
/// ```
///
/// A consumer that skips this assembly and resolves one of these protocols gets
/// `ContainerError.notRegistered` — a named failure at the composition root, not
/// an optional that degrades into silence (BR-L-06). There is no
/// `resolveOptional` path and no literal fallback anywhere in this file.
///
/// `.mock` registers the same platform implementations as `.production` for
/// logging and capacity, deliberately: a mock logger that swallows records hides
/// the thing a test is often reading, and ``MockCapacityProber`` already exists
/// for the tests that want a scripted device. Reachability in `.mock` registers
/// nothing *different* either — a test that wants a scripted interface registers
/// its own double over this one, which is the ordinary container behaviour.
public struct CoreKitPlatformAssembly: DIAssembly {
    private let subsystem: String?

    /// - Parameter subsystem: The log subsystem. Defaults to ``AppLog/subsystem``
    ///   as the host set it at launch, so a host that already configures
    ///   `AppLog.subsystem` needs to pass nothing.
    public init(subsystem: String? = nil) {
        self.subsystem = subsystem
    }

    public func assemble(container: Container, environment: DIEnvironment) {
        let subsystem = self.subsystem ?? AppLog.subsystem

        // MARK: Logging

        let logger = CoreKitPlatformDefaults.makeLogger(subsystem: subsystem)
        container.register((any LoggingProviding).self) { _ in logger }

        // `AppLog` is a deprecated STATIC facade that predates the container and
        // is called from sites that hold no resolver. Installing the resolved
        // provider here is what makes the facade and the capability one logger
        // rather than two (BR-L-07); without this line the facade would keep its
        // own seeded `SwiftLogLogger` on Apple and the two would disagree.
        AppLog.provider = logger

        // MARK: Reachability

        container.register((any ReachabilityProviding).self) { _ in
            CoreKitPlatformDefaults.makeReachability()
        }

        // MARK: Device capacity

        container.register((any DeviceCapacityProbing).self) { _ in
            CoreKitPlatformDefaults.makeCapacityProber()
        }
    }
}
