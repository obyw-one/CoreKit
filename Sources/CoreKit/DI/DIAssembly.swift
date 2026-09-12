//
//  DIAssembly.swift
//  CoreKit
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 22/02/2026.
//

import Foundation

// MARK: - DI Assembly Protocol

/// Protocol for registering a group of related dependencies.
///
/// Each assembly handles one "concern" (services, use cases, feature X, etc.)
/// and switches on the environment internally.
///
/// Assemblies are composed via `DI.configure(for:assemblies:)` and executed
/// in dependency order: Services -> UseCases -> Features.
public protocol DIAssembly {
    /// Register all dependencies this assembly owns.
    /// - Parameters:
    ///   - container: The container to register into
    ///   - environment: The target environment (.production or .mock)
    func assemble(container: Container, environment: DIEnvironment)
}

// MARK: - Resolver Convenience Extensions

public extension Resolver {
    /// Resolve a dependency or crash with a descriptive error.
    /// Use this when the dependency is required and must exist.
    @discardableResult
    func require<T>(_ type: T.Type) -> T {
        do {
            return try resolve(type)
        } catch {
            fatalError("Failed to resolve required dependency \(T.self): \(error)")
        }
    }
}
