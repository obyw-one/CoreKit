//
//  CacheRepository.swift
//  CoreKit
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 16/02/2024.
//

import Foundation
import os

// MARK: - Protocol

/// Cache-flavoured refinement of ``RepositoryProtocol``: keys are `String`,
/// and the surface adds the cache-specific extras (`exists`, the
/// reachability-aware `get`). The base protocol contributes `list()` and the
/// async spellings — existing synchronous conformers satisfy those without
/// change, since a sync method fulfils an async requirement.
///
/// Note (0.5.0): `ModelType` gains `Sendable` alongside `Codable`, inherited
/// from the base protocol. `CacheRepository` always required it.
public protocol CacheRepositoryProtocol: RepositoryProtocol where ID == String {
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
    /// Writes a `String` payload VERBATIM (UTF-8 bytes, no JSON encoding at
    /// all) and reads it back the same way — for stores whose file format is
    /// contractually NOT JSON (markdown ballots, plain-text reports). The
    /// repository's `ModelType` must be `String`; any other type throws
    /// `encodedError` on save / `decodedError` on get. TTL rides the file
    /// mtime exactly like `.raw`.
    case rawString
}

// MARK: - FileNaming

/// How a cache entry's FILENAME is derived from `(name, id)`.
///
/// The historical shape (`<name>-<id>.cache`) stays the default — every
/// existing call site keeps its bytes on disk. The other cases exist for
/// stores whose filename is a CONTRACT (consumers `cat`/`ls` them, other
/// tools glob them): shikki's `.shikki-unit.json` worktree manifests,
/// `pr-<n>.dossier.json` caches, `pr-<n>-<sha>.md` ballots.
public enum FileNaming: Sendable {
    /// Historical `"<name>-<id>.cache"` — the default, back-compat by
    /// construction.
    case legacy
    /// The `id` IS the filename, with an optional extension appended:
    /// `.bareId(ext: "json")` + id `"pr-7.dossier"` → `pr-7.dossier.json`;
    /// `.bareId()` + id `".shikki-unit.json"` → `.shikki-unit.json`.
    case bareId(ext: String? = nil)
    /// Full control — `(name, id) -> filename`. The closure must be pure
    /// and total; the same `(name, id)` must always yield the same filename
    /// or `get` will never find what `save` wrote.
    case custom(@Sendable (_ name: String, _ id: String) -> String)
}

// MARK: - CacheCodec

/// JSON codec configuration for the `.raw` envelope.
///
/// `.container` deliberately ignores this — its on-disk shape is the
/// historical envelope and changing its byte format would invalidate every
/// existing cache. `.raw` files are the ones with human contracts
/// (`cat`/`jq`/diff), so date representation and formatting are theirs to
/// choose. `.rawString` bypasses JSON entirely.
public struct CacheCodec: Sendable, Equatable {
    public enum DateStrategy: Sendable, Equatable {
        /// Foundation default (numeric `timeIntervalSinceReferenceDate`).
        case deferredToDate
        /// ISO-8601 strings — the human-readable/`jq`-friendly form.
        case iso8601
    }

    public var dates: DateStrategy
    public var prettyPrinted: Bool
    public var sortedKeys: Bool

    public init(dates: DateStrategy = .deferredToDate, prettyPrinted: Bool = false, sortedKeys: Bool = false) {
        self.dates = dates
        self.prettyPrinted = prettyPrinted
        self.sortedKeys = sortedKeys
    }

    /// Historical `.raw` behavior — bare coders. The default.
    public static let `default` = CacheCodec()

    /// ISO-8601 dates + pretty-printed + sorted keys — the `cat`/`jq`-able
    /// shape typed file stores want (shikki `.shikki-unit.json` contract).
    public static let humanReadable = CacheCodec(dates: .iso8601, prettyPrinted: true, sortedKeys: true)

    nonisolated func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        if case .iso8601 = dates { encoder.dateEncodingStrategy = .iso8601 }
        var formatting: JSONEncoder.OutputFormatting = []
        if prettyPrinted { formatting.insert(.prettyPrinted) }
        if sortedKeys { formatting.insert(.sortedKeys) }
        encoder.outputFormatting = formatting
        return encoder
    }

    nonisolated func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        if case .iso8601 = dates { decoder.dateDecodingStrategy = .iso8601 }
        return decoder
    }
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
    private let baseDirectory: URL

    /// Time-to-live policy for cache invalidation.
    private(set) var invalidateTime: InvalidateTime

    /// On-disk shape (see `EnvelopeMode`).
    public let envelope: EnvelopeMode

    /// Filename derivation (see `FileNaming`). `.legacy` by default.
    public let naming: FileNaming

    /// JSON codec configuration — honored by `.raw` only (see `CacheCodec`).
    public let codec: CacheCodec

    /// Create a `CacheRepository`.
    ///
    /// - Parameters:
    ///   - name: filename stem — every entry is written as `"<name>-<id>.cache"`.
    ///   - invalidateTime: TTL policy. Default is `.inTime(ttl: 7 days)`.
    ///     See `InvalidateTime` for per-case guidance.
    ///   - baseDirectory: destination directory for cache files. `nil` (default)
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
    ///   - naming: filename derivation. `.legacy` (default) keeps the
    ///     historical `"<name>-<id>.cache"`; `.bareId`/`.custom` exist for
    ///     stores whose filename is a contract (see `FileNaming`).
    ///   - codec: JSON codec configuration for `.raw` files (dates /
    ///     pretty-print / sorted keys). `.container` ignores it by design —
    ///     its byte shape is the historical envelope. See `CacheCodec`.
    public init(
        _ name: String,
        invalidateTime: InvalidateTime = .inTime(ttl: 7 * 24 * 60 * 60),
        baseDirectory: URL? = nil,
        envelope: EnvelopeMode = .container,
        naming: FileNaming = .legacy,
        codec: CacheCodec = .default
    ) {
        self.name = name
        self.invalidateTime = invalidateTime
        self.envelope = envelope
        self.naming = naming
        self.codec = codec

        // Resolve storage directory with a safe fallback chain — no more `.first!`.
        let resolved: URL
        if let baseDirectory {
            resolved = baseDirectory
        } else if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            resolved = docs
        } else {
            resolved = FileManager.default.temporaryDirectory
            AppLog.cache.warning("CacheRepository: .documentDirectory unavailable — falling back to temporaryDirectory at \(resolved.path)")
        }
        self.baseDirectory = resolved

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

    /// Enumerate every record this cache holds (``RepositoryProtocol/list()``).
    /// Scans the document directory for this cache's `<name>-<id>.cache`
    /// files and decodes each container; entries that fail to decode or have
    /// expired are skipped rather than failing the whole enumeration.
    nonisolated public func list() throws -> [ModelType] {
        let fm = FileManager.default
        let prefix = name + "-"
        let entries = (try? fm.contentsOfDirectory(
            at: documentPath,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var out: [ModelType] = []
        for url in entries {
            let filename = url.lastPathComponent
            guard filename.hasPrefix(prefix), filename.hasSuffix(".cache") else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            guard var container = try? JSONDecoder()
                .decode(CacheContainerModel<ModelType>.self, from: data) else { continue }
            guard (try? cacheIsValid(&container, hasNetwork: true)) == true else { continue }
            if let model = try? container.decoded() { out.append(model) }
        }
        return out
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
                toData = try codec.makeEncoder().encode(data)
            case .rawString:
                guard let text = data as? String else {
                    AppLog.cache.error("Cache save error: .rawString requires ModelType == String, got \(ModelType.self)")
                    throw CacheRepositoryError.encodedError
                }
                toData = Data(text.utf8)
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
                let data = try codec.makeDecoder().decode(ModelType.self, from: localCache)
                AppLog.cache.debug("CacheRepository: get local data (.raw)")
                return data
            } catch {
                AppLog.cache.error("Data in cache not decoded (.raw): \(error)")
                throw CacheRepositoryError.decodedError
            }

        case .rawString:
            // Verbatim UTF-8 — same mtime-TTL rule as .raw.
            if rawIsExpired(fileUrl: fileUrl), hasNetwork {
                try invalidateCache(id)
                throw CacheRepositoryError.noCacheAvailable
            }
            guard let text = String(data: localCache, encoding: .utf8),
                  let model = text as? ModelType
            else {
                AppLog.cache.error("Data in cache not decoded (.rawString requires ModelType == String, got \(ModelType.self))")
                throw CacheRepositoryError.decodedError
            }
            AppLog.cache.debug("CacheRepository: get local data (.rawString)")
            return model
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
        let filename: String
        switch naming {
        case .legacy:
            filename = name + "-" + id + ".cache"
        case .bareId(let ext):
            filename = ext.map { "\(id).\($0)" } ?? id
        case .custom(let derive):
            filename = derive(name, id)
        }
        return baseDirectory.appendingPathComponent(filename)
    }
}
