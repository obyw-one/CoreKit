//
//  CacheRepository.swift
//  CoreKit
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 16/02/2024.
//

import Foundation
import os

// MARK: - Protocol

public protocol CacheRepositoryProtocol {
    associatedtype ModelType: Codable

    func exists(_ id: String) -> Bool
    func get(_ id: String) throws -> ModelType
    func get(_ id: String, checkNetworkReachability: Bool) async throws -> ModelType
    func save(_ id: String, data: ModelType) throws
    func delete(_ id: String) throws
}

// MARK: - Errors

public enum CacheRepositoryError: Error, Sendable {
    case cannotCreateCache
    case notFound
    case noCacheAvailable
    case encodedError
    case decodedError
    case deleteError
    case invalidateCache
}

// MARK: - Invalidation Policy

public enum InvalidateTime: Codable, Sendable {
    case never
    case inTime(ttl: TimeInterval)
}

// MARK: - Internal Container

fileprivate struct CacheContainerModel<ModelType: Codable>: Codable, Sendable where ModelType: Sendable {
    var timestamp: TimeInterval
    var modelType: String
    var body: String // Serialized ref of ModelType data
    var invalideTime: InvalidateTime
    var readCount: Int

    nonisolated init(data: ModelType, invalideTime: InvalidateTime, readCount: Int = 0, timestamp: TimeInterval = Date().timeIntervalSince1970) throws {
        do {
            let serializedData = try JSONEncoder().encode(data)
            let serializedStr = String(data: serializedData, encoding: .utf8)
            guard let serialized = serializedStr, serialized.count > 0 else {
                throw CacheRepositoryError.encodedError
            }

            self.timestamp = timestamp
            self.modelType = String(describing: type(of: data.self))
            self.body = serialized
            self.invalideTime = invalideTime
            self.readCount = readCount
        } catch let error as CacheRepositoryError {
            throw error
        } catch {
            AppLog.cache.error("Cache error: \(error)")
            throw CacheRepositoryError.cannotCreateCache
        }
    }

    nonisolated func decoded() throws -> ModelType {
        guard let data = body.data(using: .utf8) else {
            throw CacheRepositoryError.decodedError
        }
        return try JSONDecoder().decode(ModelType.self, from: data)
    }

    // Explicit Codable implementation to prevent main actor isolation
    private enum CodingKeys: String, CodingKey {
        case timestamp
        case modelType
        case body
        case invalideTime
        case readCount
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        modelType = try container.decode(String.self, forKey: .modelType)
        body = try container.decode(String.self, forKey: .body)
        invalideTime = try container.decode(InvalidateTime.self, forKey: .invalideTime)
        readCount = try container.decode(Int.self, forKey: .readCount)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(modelType, forKey: .modelType)
        try container.encode(body, forKey: .body)
        try container.encode(invalideTime, forKey: .invalideTime)
        try container.encode(readCount, forKey: .readCount)
    }
}

// MARK: - CacheRepository

nonisolated public struct CacheRepository<T: Codable & Sendable>: CacheRepositoryProtocol, @unchecked Sendable {
    public typealias ModelType = T

    /// Name of the file where cached data is saved.
    public let name: String

    /// Base directory for cache storage.
    ///
    /// Defaults to the user's Documents directory (app-cache use case). CLI
    /// tools and per-project caches (e.g. `shi-moto`'s `.moto-cache/`) pass an
    /// explicit `baseDirectory` so the cache lives alongside the project
    /// instead of in `~/Documents`. The directory is created on first `save`
    /// if it does not yet exist.
    private let baseDirectory: URL

    /// Time-to-live policy for cache invalidation.
    private(set) var invalidateTime: InvalidateTime

    /// - Parameters:
    ///   - name: Namespace prefix for the on-disk filename.
    ///   - invalidateTime: TTL policy (default: 7 days).
    ///   - baseDirectory: Directory to store cache files in. Defaults to the
    ///     user's Documents directory for back-compatibility with the
    ///     app-cache use case. Pass a project-relative directory (e.g.
    ///     `.moto-cache/`) for CLI / per-project caches.
    public init(
        _ name: String,
        invalidateTime: InvalidateTime = .inTime(ttl: 7 * 24 * 60 * 60),
        baseDirectory: URL? = nil
    ) {
        self.name = name
        self.invalidateTime = invalidateTime
        self.baseDirectory = baseDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    nonisolated public func exists(_ id: String) -> Bool {
        let fileUrl = self.fileUrl(id)
        return FileManager.default.fileExists(atPath: fileUrl.relativePath)
    }

    nonisolated public func get(_ id: String) throws -> ModelType {
        guard exists(id) else {
            throw CacheRepositoryError.notFound
        }

        let fileUrl = self.fileUrl(id)
        guard let localCache = try? Data(contentsOf: fileUrl) else {
            throw CacheRepositoryError.notFound
        }

        do {
            var container = try JSONDecoder().decode(CacheContainerModel<ModelType>.self, from: localCache)
            // Synchronous version - only checks TTL, not network status
            if try cacheIsValid(&container, hasNetwork: true) {
                let data = try container.decoded()
                AppLog.cache.debug("CacheRepository: get local data")
                return data
            } else {
                try invalidateCache(id)
            }

            throw CacheRepositoryError.noCacheAvailable
        } catch let error as CacheRepositoryError {
            throw error
        } catch {
            AppLog.cache.error("Data in cache not decoded: \(error)")
            throw CacheRepositoryError.decodedError
        }
    }

    /// Async version that checks network reachability.
    /// When offline, expired cache is still considered valid for offline support.
    nonisolated public func get(_ id: String, checkNetworkReachability: Bool) async throws -> ModelType {
        guard exists(id) else {
            throw CacheRepositoryError.notFound
        }

        let fileUrl = self.fileUrl(id)
        guard let localCache = try? Data(contentsOf: fileUrl) else {
            throw CacheRepositoryError.notFound
        }

        do {
            var container = try JSONDecoder().decode(CacheContainerModel<ModelType>.self, from: localCache)

            // Check network status for offline support
            let hasNetwork: Bool
            if checkNetworkReachability {
                let interfaceType = await NetworkStatus.currentInterfaceType
                hasNetwork = interfaceType != nil && interfaceType != .unknown
            } else {
                hasNetwork = true
            }

            if try cacheIsValid(&container, hasNetwork: hasNetwork) {
                let data = try container.decoded()
                AppLog.cache.debug("CacheRepository: get local data")
                return data
            } else {
                try invalidateCache(id)
            }

            throw CacheRepositoryError.noCacheAvailable
        } catch let error as CacheRepositoryError {
            throw error
        } catch {
            AppLog.cache.error("Data in cache not decoded: \(error)")
            throw CacheRepositoryError.decodedError
        }
    }

    nonisolated public func save(_ id: String, data: ModelType) throws {
        let fileUrl = self.fileUrl(id)

        do {
            // Ensure the base directory exists (custom base dirs — e.g. a
            // project-relative `.moto-cache/` — may not exist on first save;
            // the Documents directory always does, so this is a no-op there).
            try FileManager.default.createDirectory(
                at: baseDirectory,
                withIntermediateDirectories: true
            )
            let container = try CacheContainerModel(data: data, invalideTime: invalidateTime)
            let toData = try JSONEncoder().encode(container)
            try toData.write(to: fileUrl, options: .atomic)
        } catch {
            AppLog.cache.error("Cache save error: \(error)")
            throw CacheRepositoryError.encodedError
        }
    }

    nonisolated public func delete(_ id: String) throws {
        guard exists(id) else {
            throw CacheRepositoryError.notFound
        }

        let fileUrl = self.fileUrl(id)
        do {
            try FileManager.default.removeItem(at: fileUrl)
        } catch let error {
            AppLog.cache.warning("Cache delete failed: \(error)")
            throw CacheRepositoryError.deleteError
        }
    }

    /// Checks if the cache is valid based on TTL and network reachability.
    /// - Parameters:
    ///   - container: The cached data container
    ///   - hasNetwork: Whether network connectivity is available
    /// - Returns: `true` if cache should be used, `false` if it should be invalidated
    /// - Note: When offline (`hasNetwork` is `false`), expired cache is still considered valid
    ///         to support offline mode functionality.
    nonisolated private func cacheIsValid(_ container: inout CacheContainerModel<ModelType>, hasNetwork: Bool) throws -> Bool {
        // Never invalidate cache if configured as such
        if case .never = invalidateTime { return true }

        // Check if Time To Live is OK
        if case .inTime(let ttl) = invalidateTime {
            let isExpired = container.timestamp + ttl <= Date().timeIntervalSince1970

            // If cache is fresh, use it
            if !isExpired {
                return true
            }

            // Cache is expired - check network status for offline support
            // If offline, use expired cache anyway (offline mode)
            // If online, invalidate and let caller fetch fresh data
            return !hasNetwork
        }

        return false
    }

    nonisolated private func invalidateCache(_ id: String) throws {
        do {
            try delete(id)
        } catch {
            AppLog.cache.error("Cache invalidation error: \(error)")
            throw CacheRepositoryError.invalidateCache
        }
    }

    nonisolated private func fileUrl(_ id: String) -> URL {
        let filename = name + "-" + id + ".cache"
        let fileUrl = baseDirectory.appendingPathComponent(filename)
        return fileUrl
    }
}
