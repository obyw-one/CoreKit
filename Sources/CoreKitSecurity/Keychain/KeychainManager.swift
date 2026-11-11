//
//  KeychainManager.swift
//  CoreKitSecurity
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 17/02/2026.
//

#if canImport(Security)

import CoreKit
import Foundation
import Security

/// Protocol for keychain access operations.
///
/// The requirements are `async` so a test double can be an `actor` the compiler
/// checks, instead of an `NSLock` behind `@unchecked Sendable` — a box that only
/// exists because a callback is synchronous (CoreKit#39 review). The real
/// ``KeychainManager`` keeps its synchronous Security-framework calls: a
/// synchronous method satisfies an `async` requirement.
public protocol KeychainManagerProtocol: Sendable {
    func save(_ value: String, for key: String) async throws
    func get(_ key: String) async -> String?
    func delete(_ key: String) async throws
}

/// Thin wrapper around the Security framework keychain APIs.
nonisolated public struct KeychainManager: KeychainManagerProtocol, Sendable {

    private let service: String
    private let accessGroup: String?

    public init(service: String = AppIdentity.bundleId, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func save(_ value: String, for key: String) throws {
        guard let valueData = value.data(using: .utf8) else {
            throw KeychainError.saveFailed
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: valueData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        // Delete existing item if it exists
        SecItemDelete(query as CFDictionary)

        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed
        }
    }

    public func get(_ key: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    public func delete(_ key: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed
        }
    }
}

#endif
