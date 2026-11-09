//
//  MockAuthPersistenceManager.swift
//  CoreKitSecurity
//
//  Created for testing — in-memory auth persistence.
//

#if canImport(Security)

import Foundation

/// In-memory mock of ``AuthPersistenceManagerProtocol`` for unit tests.
public final class MockAuthPersistenceManager<User: Codable & Sendable>: AuthPersistenceManagerProtocol, @unchecked Sendable {

    private let lock = NSLock()
    private var accessToken: String?
    private var refreshToken: String?
    private var user: User?

    public init() {}

    public func saveTokens(accessToken: String, refreshToken: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    public func getTokens() -> (accessToken: String?, refreshToken: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (accessToken, refreshToken)
    }

    public func clearTokens() throws {
        lock.lock()
        defer { lock.unlock() }
        accessToken = nil
        refreshToken = nil
    }

    public func saveUser(_ user: User) throws {
        lock.lock()
        defer { lock.unlock() }
        self.user = user
    }

    public func getUser() -> User? {
        lock.lock()
        defer { lock.unlock() }
        return user
    }

    public func clearUser() throws {
        lock.lock()
        defer { lock.unlock() }
        user = nil
    }

    public func clearAll() throws {
        lock.lock()
        defer { lock.unlock() }
        accessToken = nil
        refreshToken = nil
        user = nil
    }

    /// Resets all stored state.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        accessToken = nil
        refreshToken = nil
        user = nil
    }
}

#endif
