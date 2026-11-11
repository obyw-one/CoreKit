#if canImport(Security)

import Foundation

/// In-memory mock of ``AuthPersistenceManagerProtocol`` for unit tests.
///
/// An `actor`, for the same reason as ``MockKeychainManager``: the protocol's
/// requirements are `async`, so no lock box is needed (CoreKit#39 review).
public actor MockAuthPersistenceManager<User: Codable & Sendable>: AuthPersistenceManagerProtocol {

    private var accessToken: String?
    private var refreshToken: String?
    private var user: User?

    public init() {}

    public func saveTokens(accessToken: String, refreshToken: String) throws {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    public func getTokens() -> (accessToken: String?, refreshToken: String?) {
        (accessToken, refreshToken)
    }

    public func clearTokens() throws {
        accessToken = nil
        refreshToken = nil
    }

    public func saveUser(_ user: User) throws {
        self.user = user
    }

    public func getUser() -> User? {
        user
    }

    public func clearUser() throws {
        user = nil
    }

    public func clearAll() throws {
        reset()
    }

    /// Resets all stored state.
    public func reset() {
        accessToken = nil
        refreshToken = nil
        user = nil
    }
}

#endif
