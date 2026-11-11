//
//  AuthPersistenceManagerTests.swift
//  CoreKitSecurityTests
//

#if canImport(Security)

import CoreKit
import CoreKitTestSupport
import Foundation
import Testing
@testable import CoreKitSecurity

/// A simple Codable user model for testing ``AuthPersistenceManager``.
struct TestUser: Codable, Sendable, Equatable {
    let id: Int
    let name: String
}

/// Tests for ``AuthPersistenceManager`` using mock keychain and mock auth persistence.
@Suite("AuthPersistenceManager")
struct AuthPersistenceManagerTests {

    // MARK: - Token tests (mock-based, no disk I/O)

    @Test("Save and retrieve tokens")
    func saveAndGetTokens() async throws {
        let mock = MockAuthPersistenceManager<TestUser>()
        try await mock.saveTokens(accessToken: "access123", refreshToken: "refresh456")
        let tokens = await mock.getTokens()
        #expect(tokens.accessToken == "access123")
        #expect(tokens.refreshToken == "refresh456")
    }

    @Test("Clear tokens")
    func clearTokens() async throws {
        let mock = MockAuthPersistenceManager<TestUser>()
        try await mock.saveTokens(accessToken: "a", refreshToken: "r")
        try await mock.clearTokens()
        let tokens = await mock.getTokens()
        #expect(tokens.accessToken == nil)
        #expect(tokens.refreshToken == nil)
    }

    @Test("Save and retrieve user")
    func saveAndGetUser() async throws {
        let mock = MockAuthPersistenceManager<TestUser>()
        let user = TestUser(id: 1, name: "Alice")
        try await mock.saveUser(user)
        let retrieved = await mock.getUser()
        #expect(retrieved == user)
    }

    @Test("Clear user")
    func clearUser() async throws {
        let mock = MockAuthPersistenceManager<TestUser>()
        try await mock.saveUser(TestUser(id: 1, name: "Bob"))
        try await mock.clearUser()
        #expect(await mock.getUser() == nil)
    }

    @Test("Clear all removes tokens and user")
    func clearAll() async throws {
        let mock = MockAuthPersistenceManager<TestUser>()
        try await mock.saveTokens(accessToken: "a", refreshToken: "r")
        try await mock.saveUser(TestUser(id: 1, name: "Charlie"))
        try await mock.clearAll()
        let tokens = await mock.getTokens()
        #expect(tokens.accessToken == nil)
        #expect(tokens.refreshToken == nil)
        #expect(await mock.getUser() == nil)
    }

    // MARK: - Integration: real AuthPersistenceManager with MockKeychainManager

    /// The real manager over a scratch directory: since CoreKit 0.14.0 the cache
    /// is passed in, never defaulted to a location nobody chose.
    private static func realManager(keychain: MockKeychainManager) throws -> AuthPersistenceManager<TestUser> {
        let directory = try TestScratch.forPackage().makeScratchDir(scope: "auth-persistence")
        return AuthPersistenceManager<TestUser>(
            keychainManager: keychain,
            cacheRepository: CacheRepository<TestUser>("user", invalidateTime: .never, baseDirectory: directory))
    }

    @Test("AuthPersistenceManager round-trips the user through its cache repository")
    func realManagerUser() async throws {
        let manager = try Self.realManager(keychain: MockKeychainManager())
        let user = TestUser(id: 7, name: "Dana")
        try await manager.saveUser(user)
        #expect(await manager.getUser() == user)
        try await manager.clearUser()
        #expect(await manager.getUser() == nil)
    }

    @Test("AuthPersistenceManager saves and retrieves tokens via mock keychain")
    func realManagerTokens() async throws {
        let mockKeychain = MockKeychainManager()
        let manager = try Self.realManager(keychain: mockKeychain)
        try await manager.saveTokens(accessToken: "at", refreshToken: "rt")
        let tokens = await manager.getTokens()
        #expect(tokens.accessToken == "at")
        #expect(tokens.refreshToken == "rt")
    }

    @Test("AuthPersistenceManager clears tokens via mock keychain")
    func realManagerClearTokens() async throws {
        let mockKeychain = MockKeychainManager()
        let manager = try Self.realManager(keychain: mockKeychain)
        try await manager.saveTokens(accessToken: "at", refreshToken: "rt")
        try await manager.clearTokens()
        let tokens = await manager.getTokens()
        #expect(tokens.accessToken == nil)
        #expect(tokens.refreshToken == nil)
    }
}

#endif
