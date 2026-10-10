//
//  DI.swift
//  CoreKit
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 20/02/2026.
//

import Foundation

// MARK: - Dependency Injection Module

// Dependency Injection Module
//
// This file provides the main entry point for all DI-related types.
// The DI system uses a single `Container.default` variable that gets configured
// differently based on the environment (Production or Mock).
//
// ## Quick Start
//
// ### 1. Configure the Container at App Launch
//
// ```swift
// @main
// struct MyApp: App {
//     init() {
//         DI.configure(for: .production, assemblies: [
//             DIAssemblyServices(),
//             DIAssemblyUseCases(),
//             DIAssemblyLogin(),
//         ])
//     }
// }
// ```
//
// ### 2. Register Your Classes (in Assembly files)
//
// ```swift
// // In DIAssemblyServices.swift
// struct DIAssemblyServices: DIAssembly {
//     func assemble(container: Container, environment: DIEnvironment) {
//         switch environment {
//         case .production:
//             try! container.register(NetworkProtocol.self) { _ in NetworkService() }
//         case .mock:
//             try! container.register(NetworkProtocol.self) { _ in MockNetworkService() }
//         }
//     }
// }
// ```
//
// ### 3. Resolve Dependencies
//
// ```swift
// let viewModel = try Container.default.resolve(MyViewModel.self)
// // or use @Resolve property wrapper
// @Resolve var crudUseCase: any CRUDUseCaseProtocol
// ```
//
// ### 4. For SwiftUI Previews
//
// ```swift
// #Preview {
//     DI.configure(for: .mock, assemblies: [MockAssembly()])
//     MyView()
// }
// ```
//
// ## Files in this Module
//
// | File | Purpose |
// |------|---------|
// | `Container.swift` | Core DI container with registration & resolution |
// | `DIEnvironment.swift` | Environment enum (.production, .mock) |
// | `DIAssembly.swift` | Protocol for assembly-by-concern registrations |
// | `Resolve.swift` | @Resolve property wrapper |
//

// MARK: - DI Namespace

// swiftlint:disable type_name
/// Namespace for DI configuration helpers.
/// The name predates the fleet lint's 3-character floor and is the public API
/// every consumer spells (`DI.configure`, `DI.reset`); it stays.
public enum DI {
    // swiftlint:enable type_name
    // MARK: - Public API

    /// Configure the default container for the given environment with the provided assemblies.
    ///
    /// - Parameters:
    ///   - environment: `.production` for real services, `.mock` for fake data
    ///   - assemblies: Array of `DIAssembly` conforming types, in dependency order
    /// - Returns: The configured container
    @discardableResult
    public static func configure(for environment: DIEnvironment, assemblies: [DIAssembly]) -> Container {
        let container = Container(name: environment.rawValue.capitalized)
        for assembly in assemblies {
            assembly.assemble(container: container, environment: environment)
        }
        Container.default = container
        markConfigured(true)
        return container
    }

    /// Configure the default container with eager and lazy assemblies.
    ///
    /// Eager assemblies are assembled immediately (use for foundational types like Services, UseCases).
    /// Lazy assemblies are deferred until their types are first resolved (use for feature assemblies).
    ///
    /// - Parameters:
    ///   - environment: `.production` for real services, `.mock` for fake data
    ///   - assemblies: Assemblies to run immediately (in dependency order)
    ///   - lazyAssemblies: Assemblies to defer until first resolve miss
    /// - Returns: The configured container
    @discardableResult
    public static func configure(
        for environment: DIEnvironment,
        assemblies: [DIAssembly],
        lazyAssemblies: [DIAssembly]
    ) -> Container {
        let container = Container(name: environment.rawValue.capitalized)
        for assembly in assemblies {
            assembly.assemble(container: container, environment: environment)
        }
        for assembly in lazyAssemblies {
            container.addLazyAssembly(assembly, environment: environment)
        }
        Container.default = container
        markConfigured(true)
        return container
    }

    /// Reset the container (useful for testing)
    public static func reset() {
        Container.default.cleanup()
        Container.default = Container(name: "Default")
        markConfigured(false)
    }

    // MARK: - Configure once, require (0.10.1)

    /// Whether `configure(for:assemblies:)` has run since the last `reset()`.
    /// Guarded by `stateLock`; `configureIfNeeded` serialises the first
    /// configuration under `onceLock` so two tasks racing on first use never
    /// build two containers.
    nonisolated(unsafe) private static var configured = false
    private static let stateLock = NSLock()
    private static let onceLock = NSLock()

    private static func markConfigured(_ value: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        configured = value
    }

    /// `true` once a `configure` ran and until `reset()`.
    public static var isConfigured: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return configured
    }

    /// Configure the default container ONCE. The first caller runs
    /// `assemblies()` and configures; every later caller, from any thread or
    /// task, gets the container that is already there. `reset()` arms it
    /// again.
    ///
    /// Why it lives here (shikki#1784 review, 2026-10-10): a process whose
    /// entry point never composed the container — a test bundle, a plugin
    /// host, a CLI preflight — must not crash on its first `require`, and two
    /// tasks racing on that first use must not build two containers. WHICH
    /// assemblies and WHICH environment stay the app's knowledge (it passes
    /// them); only the once-mechanism is the kit's.
    ///
    /// - Parameters:
    ///   - environment: the environment to configure with when nothing is configured yet
    ///   - assemblies: built only when a configuration is needed
    /// - Returns: the default container, configured
    @discardableResult
    public static func configureIfNeeded(
        for environment: DIEnvironment,
        assemblies: () -> [DIAssembly]
    ) -> Container {
        onceLock.lock()
        defer { onceLock.unlock() }
        if isConfigured { return Container.default }
        return configure(for: environment, assemblies: assemblies())
    }

    /// Resolve from the default container, or crash naming the registration
    /// that is missing — the non-throwing twin of the module-level
    /// `resolve()`, for call sites where an absent registration is a
    /// programming error, never a runtime condition.
    public static func require<T>(_ type: T.Type = T.self) -> T {
        Container.default.require(type)
    }
}
