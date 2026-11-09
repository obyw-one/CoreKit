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
    func saveAndGet() throws {
        try keychain.save("secret123", for: "token")
        let value = keychain.get("token")
        #expect(value == "secret123")
    }

    @Test("Get returns nil for missing key")
    func getMissing() {
        let value = keychain.get("nonexistent")
        #expect(value == nil)
    }

    @Test("Overwrite an existing value")
    func overwrite() throws {
        try keychain.save("first", for: "key")
        try keychain.save("second", for: "key")
        let value = keychain.get("key")
        #expect(value == "second")
    }

    @Test("Delete an existing value")
    func deleteExisting() throws {
        try keychain.save("value", for: "key")
        try keychain.delete("key")
        let value = keychain.get("key")
        #expect(value == nil)
    }

    @Test("Delete a missing key throws itemNotFound")
    func deleteMissing() {
        #expect(throws: KeychainError.itemNotFound) {
            try keychain.delete("nonexistent")
        }
    }

    @Test("Count tracks stored items")
    func count() throws {
        #expect(keychain.count == 0)
        try keychain.save("a", for: "k1")
        try keychain.save("b", for: "k2")
        #expect(keychain.count == 2)
        try keychain.delete("k1")
        #expect(keychain.count == 1)
    }

    @Test("Reset clears all items")
    func reset() throws {
        try keychain.save("a", for: "k1")
        try keychain.save("b", for: "k2")
        keychain.reset()
        #expect(keychain.count == 0)
        #expect(keychain.get("k1") == nil)
    }
}

#endif
