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
        case .notRegistered(let type):
            "ContainerError: '\(type)' is not registered in the container"
        case .circularDependency(let path):
            "ContainerError: Circular dependency detected: \(path)"
        case .resolutionFailed(let type, let underlying):
            "ContainerError: Failed to resolve '\(type)': \(underlying.localizedDescription)"
        case .invalidRegistration(let message):
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

    /// THE FACTORY NEVER RUNS UNDER THE LOCK.
    ///
    /// It used to: `lock.lock(); defer { unlock }` wrapped the whole switch,
    /// so arbitrary user code — which may itself resolve further
    /// dependencies — ran while holding a blocking NSLock. From an async
    /// context that starves the cooperative thread pool: 20 tasks block
    /// pool threads waiting, and the holder may never be scheduled to
    /// release. WabiSabi's suite did not assert-fail on this, it HUNG — the
    /// runner restarted five times before xcodebuild gave up at 600 s.
    ///
    /// The lock now guards only the instance field. A cached factory may run
    /// more than once under contention, but exactly one result is PUBLISHED
    /// and every caller gets that one — which is what `.cached` promises.
    /// Losing a redundant instance is the correct trade against a deadlock.
    func resolve(using resolver: Resolver) throws -> Any {
        switch scope {
        case .transient:
            return try factory(resolver)

        case .cached:
            lock.lock()
            let existing = instance
            lock.unlock()
            if let existing { return existing }
            let candidate = try factory(resolver)
            lock.lock()
            defer { lock.unlock() }
            if let raced = instance { return raced }  // someone else published first
            instance = candidate
            return candidate

        case .weak:
            lock.lock()
            let existingWeak = weakInstance as? T
            lock.unlock()
            if let existingWeak { return existingWeak }
            let candidate = try factory(resolver)
            lock.lock()
            defer { lock.unlock() }
            if let raced = weakInstance as? T { return raced }
            weakInstance = candidate as AnyObject
            return candidate
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

/// Per-RESOLUTION-SCOPE stacks used to detect circular dependencies.
///
/// Was `Thread.current.threadDictionary`. That is wrong under structured
/// concurrency and failed in exactly the ways the tests describe:
///
///   - tasks in a `withThrowingTaskGroup` SHARE the cooperative thread pool,
///     so two concurrent resolutions landed on one thread and saw each
///     other's stack — a false circular-dependency report
///     (`testTaskGroupResolutionsWithDependenciesDoNotFalseDetectCycles`)
///   - an `async` task may resume on a DIFFERENT thread than it suspended
///     on, so a push and its matching pop could target different stacks,
///     leaking entries into unrelated work
///
/// `@TaskLocal` binds to the task, not the thread: it inherits into child
/// tasks structurally, is invisible to siblings, and unwinds with the scope
/// — which is the shape circular-dependency detection actually needs.
enum ResolutionStack {
    /// Keyed by context so sibling containers never share a stack, even
    /// when they carry the same `name`.
    @TaskLocal static var stacks: [String: [String]] = [:]
}

final class ResolutionContext: Sendable {
    private let key: String

    init() {
        self.key = "CoreKit.ResolutionContext.\(UUID().uuidString)"
    }

    /// The cycle path if `type` is already being resolved in THIS task, else nil.
    func cyclePath(for type: String) -> String? {
        let stack = ResolutionStack.stacks[key] ?? []
        guard stack.contains(type) else { return nil }
        return (stack + [type]).joined(separator: " → ")
    }

    /// Run `body` with `type` pushed onto this task's stack. Scope-bound, so
    /// there is no pop to forget and nothing survives a thrown error.
    func withResolving<R>(_ type: String, _ body: () throws -> R) rethrows -> R {
        var next = ResolutionStack.stacks
        next[key] = (next[key] ?? []) + [type]
        return try ResolutionStack.$stacks.withValue(next, operation: body)
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

        // Circular dependency detection, scoped to THIS task.
        if let cyclePath = context.cyclePath(for: typeName) {
            throw ContainerError.circularDependency(cyclePath)
        }

        return try context.withResolving(typeName) {
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
    }

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
