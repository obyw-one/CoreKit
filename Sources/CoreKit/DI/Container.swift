//
//  Container.swift
//  CoreKit
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 20/02/2026.
//  Dependency Injection Container with Swinject-style API
//  Features: Circular dependency detection, Memory leak prevention, Resolver protocol
//

import Foundation
import os

// MARK: - Container Error

public enum ContainerError: Error, LocalizedError, CustomStringConvertible {
    case notRegistered(String)
    case circularDependency(String)
    case resolutionFailed(String, underlying: Error)
    case invalidRegistration(String)

    public var description: String {
        switch self {
        case let .notRegistered(type):
            "ContainerError: '\(type)' is not registered in the container"
        case let .circularDependency(path):
            "ContainerError: Circular dependency detected: \(path)"
        case let .resolutionFailed(type, underlying):
            "ContainerError: Failed to resolve '\(type)': \(underlying.localizedDescription)"
        case let .invalidRegistration(message):
            "ContainerError: Invalid registration: \(message)"
        }
    }

    public var errorDescription: String? {
        description
    }
}

// MARK: - Registration Scope

public enum RegistrationScope: Sendable {
    /// New instance created every time (no caching)
    case transient
    /// Single instance per container (singleton pattern)
    case cached
    /// Weak reference - instance can be deallocated, recreated on next resolve
    case weak
}

// MARK: - Resolver Protocol (Swinject-style)

/// Protocol for resolving dependencies (passed to factory closures)
public protocol Resolver {
    /// Resolve a dependency by type
    func resolve<T>(_ type: T.Type) throws -> T

    /// Resolve a dependency by type with name (for multiple registrations)
    func resolve<T>(_ type: T.Type, name: String) throws -> T

    /// Resolve optional dependency (returns nil if not registered)
    func resolveOptional<T>(_ type: T.Type) -> T?
}

// MARK: - Registration Protocol

protocol RegistrationProtocol {
    var scope: RegistrationScope { get }
    func resolve(using resolver: Resolver) throws -> Any
    func resetInstance()
}

// MARK: - Registration

class Registration<T>: RegistrationProtocol {
    let scope: RegistrationScope
    let factory: (Resolver) throws -> T

    private var instance: T?
    private weak var weakInstance: AnyObject?
    private let lock = NSLock()

    init(scope: RegistrationScope, factory: @escaping (Resolver) throws -> T) {
        self.scope = scope
        self.factory = factory
    }

    func resolve(using resolver: Resolver) throws -> Any {
        lock.lock()
        defer { lock.unlock() }

        switch scope {
        case .transient:
            return try factory(resolver)

        case .cached:
            if let existing = instance {
                return existing
            }
            let newInstance = try factory(resolver)
            instance = newInstance
            return newInstance

        case .weak:
            if let weakRef = weakInstance, let existing = weakRef as? T {
                return existing
            }
            let newInstance = try factory(resolver)
            weakInstance = newInstance as AnyObject
            return newInstance
        }
    }

    func resetInstance() {
        lock.lock()
        defer { lock.unlock() }
        instance = nil
        weakInstance = nil
    }
}

// MARK: - Resolution Context (Thread Safety + Circular Detection)

/// Per-thread, per-container resolution tracking for circular dependency detection.
///
/// Each (thread, container) pair gets its own resolution stack via `Thread.threadDictionary`,
/// so concurrent resolves on different threads don't interfere, and parent/child
/// container delegation doesn't false-detect circularity.
final class ResolutionContext {
    private let threadKey: String

    init() {
        self.threadKey = "CoreKit.ResolutionContext.\(UUID().uuidString)"
    }

    private var currentStack: [String] {
        get { Thread.current.threadDictionary[threadKey] as? [String] ?? [] }
        set { Thread.current.threadDictionary[threadKey] = newValue }
    }

    /// Push type onto the current thread's stack.
    /// Returns error string if circular dependency detected.
    func push(_ type: String) -> String? {
        var stack = currentStack
        if stack.contains(type) {
            return stack.joined(separator: " → ") + " → " + type
        }
        stack.append(type)
        currentStack = stack
        return nil
    }

    /// Pop type from the current thread's stack.
    func pop(_ type: String) {
        var stack = currentStack
        if let index = stack.lastIndex(of: type) {
            stack.remove(at: index)
        }
        currentStack = stack
    }

    /// Clear the current thread's stack.
    func clear() {
        Thread.current.threadDictionary.removeObject(forKey: threadKey)
    }
}

// MARK: - Container

/// Dependency Injection Container with Swinject-style API
open class Container: Resolver, @unchecked Sendable {
    // MARK: - Static Properties

    private static let defaultLock = NSLock()
    nonisolated(unsafe) private static var _default: Container = .init()

    /// Default shared container instance (thread-safe)
    public static var `default`: Container {
        get {
            defaultLock.lock()
            defer { defaultLock.unlock() }
            return _default
        }
        set {
            defaultLock.lock()
            defer { defaultLock.unlock() }
            _default = newValue
        }
    }

    // MARK: - Properties

    private var registrations: [String: any RegistrationProtocol] = [:]
    private var pendingAssemblies: [(assembly: DIAssembly, environment: DIEnvironment)] = []
    private let lock = NSLock()
    private let context = ResolutionContext()
    private weak var parent: Container?

    /// Container name for debugging
    public let name: String

    // MARK: - Initialization

    public init(name: String = "Container", parent: Container? = nil) {
        self.name = name
        self.parent = parent
    }

    deinit {
        cleanup()
    }

    // MARK: - Lazy Assembly Support

    /// Add an assembly to be executed lazily on first resolve miss.
    ///
    /// Lazy assemblies are triggered one-by-one when a type is not found
    /// in the container's registrations. Once an assembly provides the
    /// requested type, remaining assemblies stay pending.
    public func addLazyAssembly(_ assembly: DIAssembly, environment: DIEnvironment) {
        lock.lock()
        defer { lock.unlock() }
        pendingAssemblies.append((assembly, environment))
    }

    /// Attempt to resolve a registration key by triggering pending lazy assemblies.
    /// Returns the registration if found, nil otherwise.
    private func resolveLazyRegistration(for key: String) -> (any RegistrationProtocol)? {
        // Fast path: no pending assemblies
        lock.lock()
        guard !pendingAssemblies.isEmpty else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        // Try each pending assembly one at a time
        while true {
            lock.lock()
            guard !pendingAssemblies.isEmpty else {
                lock.unlock()
                return nil
            }
            let entry = pendingAssemblies.removeFirst()
            lock.unlock()

            // Run the assembly — this calls register() which acquires lock internally
            entry.assembly.assemble(container: self, environment: entry.environment)

            // Check if the type we need was registered
            lock.lock()
            if let reg = registrations[key] {
                lock.unlock()
                return reg
            }
            lock.unlock()
        }
    }

    // MARK: - Registration

    /// Register a factory for a type with default scope (.cached)
    @discardableResult
    public func register<T>(
        _ type: T.Type = T.self,
        name: String? = nil,
        factory: @escaping (Resolver) throws -> T
    ) -> Container {
        try! register(type, name: name, scope: .cached, factory: factory)
        return self
    }

    /// Register a factory for a type with specific scope
    @discardableResult
    public func register<T>(
        _ type: T.Type = T.self,
        name: String? = nil,
        scope: RegistrationScope,
        factory: @escaping (Resolver) throws -> T
    ) throws -> Container {
        let key = registrationKey(for: type, name: name)

        lock.lock()
        defer { lock.unlock() }

        registrations[key] = Registration(scope: scope) { resolver in
            try factory(resolver)
        }

        return self
    }

    // MARK: - Resolver Protocol

    public func resolve<T>(_ type: T.Type = T.self) throws -> T {
        try resolve(type, name: nil)
    }

    public func resolve<T>(_ type: T.Type = T.self, name: String? = nil) throws -> T {
        let key = registrationKey(for: type, name: name)
        let typeName = String(describing: type) + (name.map { "(\($0))" } ?? "")

        // Circular dependency detection
        if let cyclePath = context.push(typeName) {
            throw ContainerError.circularDependency(cyclePath)
        }

        defer { context.pop(typeName) }

        // Look up registration
        lock.lock()
        let registration = registrations[key]
        lock.unlock()

        guard let reg = registration ?? resolveLazyRegistration(for: key) else {
            // Try parent container
            if let parent {
                return try parent.resolve(type, name: name)
            }
            throw ContainerError.notRegistered(typeName)
        }

        // Resolve instance
        do {
            let resolved = try reg.resolve(using: self)
            guard let typed = resolved as? T else {
                throw ContainerError.resolutionFailed(
                    typeName,
                    underlying: NSError(
                        domain: "Container",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Type mismatch: expected \(T.self), got \(Swift.type(of: resolved))"]
                    )
                )
            }
            return typed
        } catch let error as ContainerError {
            throw error
        } catch {
            throw ContainerError.resolutionFailed(typeName, underlying: error)
        }
    }

    /// Resolve with non-optional name (for Resolver protocol conformance)
    public func resolve<T>(_ type: T.Type, name: String) throws -> T {
        try resolve(type, name: Optional(name))
    }

    public func resolveOptional<T>(_ type: T.Type = T.self) -> T? {
        try? resolve(type)
    }

    // MARK: - Instance Management

    /// Register an existing instance (singleton, always cached)
    public func registerInstance<T>(_ instance: T, for type: T.Type = T.self, name: String? = nil) {
        let key = registrationKey(for: type, name: name)

        lock.lock()
        defer { lock.unlock() }

        registrations[key] = Registration(scope: .cached) { _ in instance }
    }

    // MARK: - Cleanup (Memory Leak Prevention)

    /// Clear all cached instances (keeps registrations)
    public func resetCache() {
        lock.lock()
        defer { lock.unlock() }

        for (_, registration) in registrations {
            registration.resetInstance()
        }
    }

    /// Clear all registrations and instances
    public func cleanup() {
        lock.lock()
        defer { lock.unlock() }

        for (_, registration) in registrations {
            registration.resetInstance()
        }
        registrations.removeAll()
        pendingAssemblies.removeAll()
        context.clear()
    }

    /// Remove specific registration
    public func remove<T>(_ type: T.Type = T.self, name: String? = nil) {
        let key = registrationKey(for: type, name: name)

        lock.lock()
        defer { lock.unlock() }

        if let registration = registrations.removeValue(forKey: key) {
            registration.resetInstance()
        }
    }

    /// Check if a type is registered
    public func isRegistered<T>(_ type: T.Type = T.self, name: String? = nil) -> Bool {
        let key = registrationKey(for: type, name: name)

        lock.lock()
        defer { lock.unlock() }

        let found = registrations[key] != nil || !pendingAssemblies.isEmpty
        return found || parent?.isRegistered(type, name: name) == true
    }

    // MARK: - Debug Helpers

    /// Print all registered types (for debugging)
    public func printRegistrations() {
        lock.lock()
        defer { lock.unlock() }

        AppLog.di.debug("Container '\(self.name)' registrations:")
        for (key, _) in registrations {
            AppLog.di.debug("  - \(key)")
        }
        if let parent {
            AppLog.di.debug("Parent container '\(parent.name)':")
            parent.printRegistrations()
        }
    }

    // MARK: - Private Helpers

    private func registrationKey(for type: (some Any).Type, name: String?) -> String {
        let baseKey = String(describing: type)
        return name.map { "\(baseKey):\($0)" } ?? baseKey
    }
}

// MARK: - Global Convenience Functions

/// Resolve a dependency from the default container
public func resolve<T>(_ type: T.Type = T.self) throws -> T {
    try Container.default.resolve(type)
}

/// Resolve an optional dependency from the default container
public func resolveOptional<T>(_ type: T.Type = T.self) -> T? {
    Container.default.resolveOptional(type)
}
