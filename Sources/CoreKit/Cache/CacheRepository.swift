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

/// Time-to-live policy applied to a `CacheRepository`.
///
/// - `never`: cached entries are always considered valid; nothing ever expires.
///   Recommended when the file is a typed store for authoritative state
///   (e.g. `.raw` envelope acting as the on-disk source of truth for a value
///   the app owns) — pair with `.raw` for a cat/jq-able, non-expiring store.
/// - `inTime(ttl:)`: cached entries expire after `ttl` seconds. In `.container`
///   envelope the timestamp is stored inside the file; in `.raw` envelope the
///   file's modification date (mtime) is used instead so the payload stays a
///   clean JSON dump of `ModelType`.
public enum InvalidateTime: Codable, Sendable {
    case never
    case inTime(ttl: TimeInterval)
}

// MARK: - Envelope Mode

/// On-disk shape written by `CacheRepository`.
///
/// This is the "typed-option-description bar" for the file store — every case
/// is documented with the shape it produces and when to prefer it.
///
/// - `container` (default, legacy): wraps `ModelType` inside a
///   `CacheContainerModel` metadata envelope with `timestamp`, `modelType`,
///   `body` (serialized model as a JSON string), `invalideTime` and
///   `readCount`. Use this when you want in-file TTL bookkeeping, want to
///   keep the historical file shape for existing on-disk caches, or plan to
///   add schema-migration metadata later. This is what every existing 2-arg
///   `CacheRepository(_:invalidateTime:)` call site produces — back-compat is
///   preserved by construction.
///
/// - `raw`: encodes/decodes `ModelType` **directly** to the file so the
///   file's bytes ARE the model's JSON representation — `cat`-able,
///   `jq`-able, diff-able, human-readable. `exists` / `get` / `save` /
///   `delete` semantics are identical to `.container`; TTL is honored via
///   the file's mtime for `.inTime`. Pair with `InvalidateTime.never` when
///   the file is meant to be the canonical typed store for a domain value
///   (the shikki-side consolidation sweep uses this for
///   `UnitProvenanceStore`, `PrePrBallotCache`, and every
///   `JSONEncoder`-to-file sibling — one typed file store instead of N
///   ad-hoc `JSONEncoder().encode → try Data.write` patterns).
public enum EnvelopeMode: Sendable, Equatable {
    case container
    case raw
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

    /// Directory URL under which cache files are written.
    ///
    /// Resolved at init time from (in order):
    ///  1. the caller-supplied `directory:` (created if missing)
    ///  2. the process's `.documentDirectory`
    ///  3. the process's `temporaryDirectory` (safe fallback — replaces the
    ///     pre-existing `.first!` force-unwrap so sandboxed / non-app
    ///     environments where `.documentDirectory` returns an empty array
    ///     no longer crash)
    private let documentPath: URL

    /// Time-to-live policy for cache invalidation.
    private(set) var invalidateTime: InvalidateTime

    /// On-disk shape (see `EnvelopeMode`).
    public let envelope: EnvelopeMode

    /// Create a `CacheRepository`.
    ///
    /// - Parameters:
    ///   - name: filename stem — every entry is written as `"<name>-<id>.cache"`.
    ///   - invalidateTime: TTL policy. Default is `.inTime(ttl: 7 days)`.
    ///     See `InvalidateTime` for per-case guidance.
    ///   - directory: destination directory for cache files. `nil` (default)
    ///     keeps the historical behavior (`.documentDirectory`, with a
    ///     `temporaryDirectory` safe fallback if unavailable). A non-nil URL
    ///     stores files under that directory and creates it if missing —
    ///     useful when the caller manages an explicit typed store location
    ///     (Application Support subdirectory, XDG cache path, workspace-
    ///     scoped directory, unit-test temp dir).
    ///   - envelope: on-disk shape. Default is `.container` — the historical
    ///     `CacheContainerModel` metadata envelope. `.raw` writes the model's
    ///     JSON directly so the file is `cat`/`jq`-able. See `EnvelopeMode`
    ///     for per-case guidance. Existing 2-arg call sites keep `.container`
    ///     automatically (back-compat preserved).
    public init(
        _ name: String,
        invalidateTime: InvalidateTime = .inTime(ttl: 7 * 24 * 60 * 60),
        directory: URL? = nil,
        envelope: EnvelopeMode = .container
    ) {
        self.name = name
        self.invalidateTime = invalidateTime
        self.envelope = envelope

        // Resolve storage directory with a safe fallback chain — no more `.first!`.
        let resolved: URL
        if let directory {
            resolved = directory
        } else if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            resolved = docs
        } else {
            resolved = FileManager.default.temporaryDirectory
            AppLog.cache.warning("CacheRepository: .documentDirectory unavailable — falling back to temporaryDirectory at \(resolved.path)")
        }
        self.documentPath = resolved

        // Best-effort mkdir -p. If this fails, subsequent `save` writes will
        // surface the underlying FileManager error via `encodedError`.
        if !FileManager.default.fileExists(atPath: resolved.path) {
            do {
                try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
            } catch {
                AppLog.cache.warning("CacheRepository: could not create directory \(resolved.path): \(error)")
            }
        }
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

        // Synchronous version — only checks TTL, not network status.
        return try decode(id: id, fileUrl: fileUrl, data: localCache, hasNetwork: true)
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

        // Check network status for offline support
        let hasNetwork: Bool
        if checkNetworkReachability {
            let interfaceType = await NetworkStatus.currentInterfaceType
            hasNetwork = interfaceType != nil && interfaceType != .unknown
        } else {
            hasNetwork = true
        }

        return try decode(id: id, fileUrl: fileUrl, data: localCache, hasNetwork: hasNetwork)
    }

    nonisolated public func save(_ id: String, data: ModelType) throws {
        let fileUrl = self.fileUrl(id)

        do {
            let toData: Data
            switch envelope {
            case .container:
                let container = try CacheContainerModel(data: data, invalideTime: invalidateTime)
                toData = try JSONEncoder().encode(container)
            case .raw:
                toData = try JSONEncoder().encode(data)
            }
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

    // MARK: - Decoding (envelope-aware)

    /// Central decode path used by both sync and async `get`. Handles both
    /// envelope modes and TTL invalidation uniformly.
    nonisolated private func decode(id: String, fileUrl: URL, data localCache: Data, hasNetwork: Bool) throws -> ModelType {
        switch envelope {
        case .container:
            do {
                var container = try JSONDecoder().decode(CacheContainerModel<ModelType>.self, from: localCache)
                if try cacheIsValid(&container, hasNetwork: hasNetwork) {
                    let data = try container.decoded()
                    AppLog.cache.debug("CacheRepository: get local data (.container)")
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

        case .raw:
            // .raw has no in-file timestamp — TTL is honored via file mtime.
            if rawIsExpired(fileUrl: fileUrl), hasNetwork {
                try invalidateCache(id)
                throw CacheRepositoryError.noCacheAvailable
            }
            do {
                let data = try JSONDecoder().decode(ModelType.self, from: localCache)
                AppLog.cache.debug("CacheRepository: get local data (.raw)")
                return data
            } catch {
                AppLog.cache.error("Data in cache not decoded (.raw): \(error)")
                throw CacheRepositoryError.decodedError
            }
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

    /// TTL check for `.raw` envelope — timestamp lives in the file's mtime,
    /// not inside the payload (payload is the model itself).
    nonisolated private func rawIsExpired(fileUrl: URL) -> Bool {
        // `.never` never expires — regardless of file age.
        if case .never = invalidateTime { return false }

        if case .inTime(let ttl) = invalidateTime {
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileUrl.path)
            guard let mtime = attrs?[.modificationDate] as? Date else {
                // Can't read mtime → treat as fresh, don't destroy readable data.
                return false
            }
            return mtime.timeIntervalSince1970 + ttl <= Date().timeIntervalSince1970
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
        let fileUrl = documentPath.appendingPathComponent(filename)
        return fileUrl
    }
}
