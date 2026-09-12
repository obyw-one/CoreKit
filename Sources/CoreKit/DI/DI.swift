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

/// Namespace for DI configuration helpers
public enum DI {
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
        return container
    }

    /// Reset the container (useful for testing)
    public static func reset() {
        Container.default.cleanup()
        Container.default = Container(name: "Default")
    }
}
