//
//  KeychainManagerTests.swift
//  CoreKitSecurityTests
//

#if canImport(Security)

import Testing
@testable import CoreKitSecurity

/// Tests for ``KeychainManager`` using the in-memory ``MockKeychainManager``.
@Suite("KeychainManager")
struct KeychainManagerTests {

    let keychain = MockKeychainManager()

    @Test("Save and retrieve a value")
    func saveAndGet() async throws {
        try await keychain.save("secret123", for: "token")
        let value = await keychain.get("token")
        #expect(value == "secret123")
    }

    @Test("Get returns nil for missing key")
    func getMissing() async {
        let value = await keychain.get("nonexistent")
        #expect(value == nil)
    }

    @Test("Overwrite an existing value")
    func overwrite() async throws {
        try await keychain.save("first", for: "key")
        try await keychain.save("second", for: "key")
        let value = await keychain.get("key")
        #expect(value == "second")
    }

    @Test("Delete an existing value")
    func deleteExisting() async throws {
        try await keychain.save("value", for: "key")
        try await keychain.delete("key")
        let value = await keychain.get("key")
        #expect(value == nil)
    }

    @Test("Delete a missing key throws itemNotFound")
    func deleteMissing() async {
        await #expect(throws: KeychainError.itemNotFound) {
            try await keychain.delete("nonexistent")
        }
    }

    @Test("Count tracks stored items")
    func count() async throws {
        #expect(await keychain.isEmpty)
        try await keychain.save("a", for: "k1")
        try await keychain.save("b", for: "k2")
        #expect(await keychain.count == 2)
        try await keychain.delete("k1")
        #expect(await keychain.count == 1)
    }

    @Test("Reset clears all items")
    func reset() async throws {
        try await keychain.save("a", for: "k1")
        try await keychain.save("b", for: "k2")
        await keychain.reset()
        #expect(await keychain.isEmpty)
        #expect(await keychain.get("k1") == nil)
    }
}

#endif
