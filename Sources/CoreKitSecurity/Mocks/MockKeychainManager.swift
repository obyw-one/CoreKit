//
//  MockKeychainManager.swift
//  CoreKitSecurity
//
//  Created for testing — in-memory dictionary storage.
//

#if canImport(Security)

import Foundation

/// In-memory mock of ``KeychainManagerProtocol`` for unit tests.
///
/// Thread-safe via an actor-isolated dictionary behind `@unchecked Sendable`.
public final class MockKeychainManager: KeychainManagerProtocol, @unchecked Sendable {

    private let lock = NSLock()
    private var store: [String: String] = [:]

    public init() {}

    public func save(_ value: String, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        store[key] = value
    }

    public func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return store[key]
    }

    public func delete(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard store.removeValue(forKey: key) != nil else {
            throw KeychainError.itemNotFound
        }
    }

    /// Returns the number of items currently stored (useful for test assertions).
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return store.count
    }

    /// Removes all stored items.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
    }
}

#endif
