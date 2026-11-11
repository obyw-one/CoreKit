//
//  AuthPersistenceManager.swift
//  CoreKitSecurity
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 17/02/2026.
//

#if canImport(Security)

import CoreKit
import Foundation

/// Protocol for authentication persistence — generic over the user model.
public protocol AuthPersistenceManagerProtocol: Sendable {
    associatedtype User: Codable & Sendable

    // `async` throughout: the tokens live behind ``KeychainManagerProtocol``,
    // whose requirements are `async`, and a mock can then be an actor.
    func saveTokens(accessToken: String, refreshToken: String) async throws
    func getTokens() async -> (accessToken: String?, refreshToken: String?)
    func clearTokens() async throws
    func saveUser(_ user: User) async throws
    func getUser() async -> User?
    func clearUser() async throws
    func clearAll() async throws
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

    /// - Parameter cacheRepository: where the user model lives. REQUIRED since
    ///   CoreKit 0.14.0: the old default, `CacheRepository("user", invalidateTime:
    ///   .never)`, is the no-directory form 0.14.0 deprecated — with no
    ///   `PathResolving` registered it throws on every save instead of writing
    ///   to the documents folder. Pass one built with `baseDirectory:` or `in:`.
    nonisolated public init(
        keychainManager: KeychainManagerProtocol,
        cacheRepository: CacheRepository<User>
    ) {
        self.keychainManager = keychainManager
        self.cacheRepository = cacheRepository
    }

    public func saveTokens(accessToken: String, refreshToken: String) async throws {
        try await keychainManager.save(accessToken, for: accessTokenKey)
        try await keychainManager.save(refreshToken, for: refreshTokenKey)
    }

    public func getTokens() async -> (accessToken: String?, refreshToken: String?) {
        let accessToken = await keychainManager.get(accessTokenKey)
        let refreshToken = await keychainManager.get(refreshTokenKey)
        return (accessToken, refreshToken)
    }

    public func clearTokens() async throws {
        try await keychainManager.delete(accessTokenKey)
        try await keychainManager.delete(refreshTokenKey)
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

    public func clearAll() async throws {
        try await clearTokens()
        try clearUser()
    }
}

#endif
