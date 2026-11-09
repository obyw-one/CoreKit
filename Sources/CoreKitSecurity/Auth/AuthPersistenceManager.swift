//
//  AuthPersistenceManager.swift
//  CoreKitSecurity
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 17/02/2026.
//

#if canImport(Security)

import Foundation
import CoreKit

/// Protocol for authentication persistence — generic over the user model.
public protocol AuthPersistenceManagerProtocol: Sendable {
    associatedtype User: Codable & Sendable

    func saveTokens(accessToken: String, refreshToken: String) throws
    func getTokens() -> (accessToken: String?, refreshToken: String?)
    func clearTokens() throws
    func saveUser(_ user: User) throws
    func getUser() -> User?
    func clearUser() throws
    func clearAll() throws
}

/// Persists authentication tokens in the keychain and the user model on disk via ``CacheRepository``.
///
/// Generic over `User` so consuming apps can plug in their own user/login model.
nonisolated public struct AuthPersistenceManager<User: Codable & Sendable>: AuthPersistenceManagerProtocol, Sendable {

    nonisolated private let keychainManager: KeychainManagerProtocol
    nonisolated private let cacheRepository: CacheRepository<User>

    private let accessTokenKey = "accessToken"
    private let refreshTokenKey = "refreshToken"
    private let userKey = "currentUser"

    nonisolated public init(
        keychainManager: KeychainManagerProtocol,
        cacheRepository: CacheRepository<User> = CacheRepository("user", invalidateTime: .never)
    ) {
        self.keychainManager = keychainManager
        self.cacheRepository = cacheRepository
    }

    public func saveTokens(accessToken: String, refreshToken: String) throws {
        try keychainManager.save(accessToken, for: accessTokenKey)
        try keychainManager.save(refreshToken, for: refreshTokenKey)
    }

    public func getTokens() -> (accessToken: String?, refreshToken: String?) {
        let accessToken = keychainManager.get(accessTokenKey)
        let refreshToken = keychainManager.get(refreshTokenKey)
        return (accessToken, refreshToken)
    }

    public func clearTokens() throws {
        try keychainManager.delete(accessTokenKey)
        try keychainManager.delete(refreshTokenKey)
    }

    public func saveUser(_ user: User) throws {
        try cacheRepository.save(userKey, data: user)
    }

    public func getUser() -> User? {
        guard cacheRepository.exists(userKey) else {
            return nil
        }

        do {
            return try cacheRepository.get(userKey)
        } catch {
            return nil
        }
    }

    public func clearUser() throws {
        try cacheRepository.delete(userKey)
    }

    public func clearAll() throws {
        try clearTokens()
        try clearUser()
    }
}

#endif
