//
//  ConfigEndpoint.swift
//  CoreKit
//
//  Where the server-driven configuration comes FROM, behind one protocol
//  (spec d3f8a1b2, BR-RP-13): PocketBase, a
//  direct SQL read, or a local file are interchangeable backings, and the
//  config layer above them is backing-agnostic.
//

import Foundation

// MARK: - ConfigEndpointError

/// A refusal every ``ConfigEndpoint`` shares. Backing-specific failures
/// (a network error, a SQL error) are thrown as they are.
public enum ConfigEndpointError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// The source holds no configuration for this app and environment.
    case notFound(AppConfigQuery)

    public var description: String {
        switch self {
        case .notFound(let query):
            "No configuration for app '\(query.appId)' in environment '\(query.environment)'"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - ConfigEndpoint

/// A source of ``AppConfig``.
///
/// Implementations live where their dependency lives: the PocketBase endpoint
/// in NetKit, the SQL one in BackendKit, the file / cache one here. Every one
/// answers the same question the same way — the configuration, or a thrown
/// reason — and none defaults: a source that cannot answer throws, so the
/// service above can tell "the server said nothing" from "the server said X".
public protocol ConfigEndpoint: Sendable {

    /// The configuration for `query`.
    /// - Throws: ``ConfigEndpointError/notFound(_:)`` when the source holds none;
    ///   anything else the source raises, unchanged.
    func fetchConfig(_ query: AppConfigQuery) async throws -> AppConfig
}

// MARK: - RepositoryConfigEndpoint

/// The local, offline source: configuration held in any repository — a
/// ``CacheRepository`` over a settings file, an ``AsyncCacheRepository``, an
/// in-memory store.
///
/// This is the "CacheRepository or a settings file" backing of the spec: the
/// file is a `.raw` ``CacheRepository`` entry (the JSON of ``AppConfig``,
/// `cat`-able), found through the path layer like any other owned file.
public struct RepositoryConfigEndpoint: ConfigEndpoint {

    private let repository: any RepositoryProtocol<String, AppConfig>

    public init(repository: any RepositoryProtocol<String, AppConfig>) {
        self.repository = repository
    }

    public func fetchConfig(_ query: AppConfigQuery) async throws -> AppConfig {
        do {
            return try await repository.get(query.storageKey)
        } catch let error as CacheRepositoryError {
            guard case .notFound = error else { throw error }
            throw ConfigEndpointError.notFound(query)
        } catch let error as RepositoryError {
            guard case .notFound = error else { throw error }
            throw ConfigEndpointError.notFound(query)
        }
    }
}

// MARK: - StubConfigEndpoint

/// A scripted source for tests: answers with what it was told to, and counts
/// the questions it was asked.
public actor StubConfigEndpoint: ConfigEndpoint {

    public private(set) var requests: [AppConfigQuery] = []
    private var result: Result<AppConfig, any Error>

    public init(_ result: Result<AppConfig, any Error>) {
        self.result = result
    }

    /// What the next requests answer with.
    public func answer(with result: Result<AppConfig, any Error>) {
        self.result = result
    }

    public func fetchConfig(_ query: AppConfigQuery) async throws -> AppConfig {
        requests.append(query)
        return try result.get()
    }
}
