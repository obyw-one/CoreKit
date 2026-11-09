//
//  AuthPersistenceManagerTests.swift
//  CoreKitSecurityTests
//

#if canImport(Security)

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
    func saveAndGetTokens() throws {
        let mock = MockAuthPersistenceManager<TestUser>()
        try mock.saveTokens(accessToken: "access123", refreshToken: "refresh456")
        let tokens = mock.getTokens()
        #expect(tokens.accessToken == "access123")
        #expect(tokens.refreshToken == "refresh456")
    }

    @Test("Clear tokens")
    func clearTokens() throws {
        let mock = MockAuthPersistenceManager<TestUser>()
        try mock.saveTokens(accessToken: "a", refreshToken: "r")
        try mock.clearTokens()
        let tokens = mock.getTokens()
        #expect(tokens.accessToken == nil)
        #expect(tokens.refreshToken == nil)
    }

    @Test("Save and retrieve user")
    func saveAndGetUser() throws {
        let mock = MockAuthPersistenceManager<TestUser>()
        let user = TestUser(id: 1, name: "Alice")
        try mock.saveUser(user)
        let retrieved = mock.getUser()
        #expect(retrieved == user)
    }

    @Test("Clear user")
    func clearUser() throws {
        let mock = MockAuthPersistenceManager<TestUser>()
        try mock.saveUser(TestUser(id: 1, name: "Bob"))
        try mock.clearUser()
        #expect(mock.getUser() == nil)
    }

    @Test("Clear all removes tokens and user")
    func clearAll() throws {
        let mock = MockAuthPersistenceManager<TestUser>()
        try mock.saveTokens(accessToken: "a", refreshToken: "r")
        try mock.saveUser(TestUser(id: 1, name: "Charlie"))
        try mock.clearAll()
        let tokens = mock.getTokens()
        #expect(tokens.accessToken == nil)
        #expect(tokens.refreshToken == nil)
        #expect(mock.getUser() == nil)
    }

    // MARK: - Integration: real AuthPersistenceManager with MockKeychainManager

    @Test("AuthPersistenceManager saves and retrieves tokens via mock keychain")
    func realManagerTokens() throws {
        let mockKeychain = MockKeychainManager()
        let manager = AuthPersistenceManager<TestUser>(keychainManager: mockKeychain)
        try manager.saveTokens(accessToken: "at", refreshToken: "rt")
        let tokens = manager.getTokens()
        #expect(tokens.accessToken == "at")
        #expect(tokens.refreshToken == "rt")
    }

    @Test("AuthPersistenceManager clears tokens via mock keychain")
    func realManagerClearTokens() throws {
        let mockKeychain = MockKeychainManager()
        let manager = AuthPersistenceManager<TestUser>(keychainManager: mockKeychain)
        try manager.saveTokens(accessToken: "at", refreshToken: "rt")
        try manager.clearTokens()
        let tokens = manager.getTokens()
        #expect(tokens.accessToken == nil)
        #expect(tokens.refreshToken == nil)
    }
}

#endif
