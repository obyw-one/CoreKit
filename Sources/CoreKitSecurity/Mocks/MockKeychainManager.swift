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
/// An `actor`: its isolation is checked by the compiler. It used to be a class
/// behind `@unchecked Sendable` and an `NSLock` (CoreKit#39 review), which was
/// only necessary while the protocol's requirements were synchronous.
public actor MockKeychainManager: KeychainManagerProtocol {

    private var store: [String: String] = [:]

    public init() {}

    public func save(_ value: String, for key: String) throws {
        store[key] = value
    }

    public func get(_ key: String) -> String? {
        store[key]
    }

    public func delete(_ key: String) throws {
        guard store.removeValue(forKey: key) != nil else {
            throw KeychainError.itemNotFound
        }
    }

    /// The number of items currently stored (useful for test assertions).
    public var count: Int { store.count }

    /// Whether nothing is stored — what SwiftLint's `empty_count` rewrites
    /// `count == 0` to, so the mock answers it directly.
    public var isEmpty: Bool { store.isEmpty }

    /// Removes all stored items.
    public func reset() {
        store.removeAll()
    }
}

#endif
