//
//  CacheRepository.swift
//  CoreKit
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 16/02/2024.
//

import Foundation

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

// MARK: - CacheRepository

/// The synchronous cache: a model per entry, over a ``SynchronousCacheBacking``.
///
/// The usual backing is a local folder, and every call that names its
/// `baseDirectory:` builds exactly that and behaves exactly as before. The
/// backing is swappable (BR-RP-11): pass any ``SynchronousCacheBacking`` to the
/// `backing:` initialiser and nothing else about the consumer changes. A
/// backing that can only answer asynchronously — a database, an object store —
/// is used through ``AsyncCacheRepository``, which speaks the same envelope, TTL
/// and naming over it.
///
/// A cache with no directory at all is the deprecated legacy form: see the
/// deprecated initialiser and ``CacheDirectory``.
nonisolated public struct CacheRepository<T: Codable & Sendable>: CacheRepositoryProtocol {
    public typealias ModelType = T

    private let engine: CacheEntryEngine<T>
    private let location: Result<any SynchronousCacheBacking, CacheLocationError>
    private let requestedProfile: FileIOProfile

    /// Name of the cache — the stem of every legacy entry name.
    public var name: String { engine.name }

    /// Time-to-live policy for cache invalidation.
    var invalidateTime: InvalidateTime { engine.invalidateTime }

    /// On-disk shape (see `EnvelopeMode`).
    public var envelope: EnvelopeMode { engine.envelope }

    /// Filename derivation (see `FileNaming`). `.legacy` by default.
    public var naming: FileNaming { engine.naming }

    /// JSON codec configuration — honored by `.raw` only (see `CacheCodec`).
    public var codec: CacheCodec { engine.codec }

    /// Write-path profile controlling crash-atomicity and cross-process
    /// exclusion. Default is `.atomic` — EXACTLY today's behavior. A backing
    /// that has no file write reports `.atomic`, which is what it guarantees: a
    /// save is all-or-nothing. See ``FileIOProfile`` for per-case guidance.
    public var ioProfile: FileIOProfile {
        if case .success(let backing) = location { return backing.fileIOProfile ?? .atomic }
        return requestedProfile
    }

    /// Create a `CacheRepository` over a local folder you name.
    ///
    /// - Parameters:
    ///   - name: filename stem — every entry is written as `"<name>-<id>.cache"`.
    ///   - invalidateTime: TTL policy. Default is `.inTime(ttl: 7 days)`.
    ///     See `InvalidateTime` for per-case guidance.
    ///   - baseDirectory: destination directory for cache files; created if
    ///     missing. Pass the directory your path layer resolved, an
    ///     Application Support subdirectory, or a unit-test scratch folder.
    ///   - envelope: on-disk shape. Default is `.container` — the historical
    ///     `CacheContainerModel` metadata envelope. `.raw` writes the model's
    ///     JSON directly so the file is `cat`/`jq`-able. See `EnvelopeMode`
    ///     for per-case guidance.
    ///   - naming: filename derivation. `.legacy` (default) keeps the
    ///     historical `"<name>-<id>.cache"`; `.bareId`/`.custom` exist for
    ///     stores whose filename is a contract (see `FileNaming`).
    ///   - codec: JSON codec configuration for `.raw` files (dates /
    ///     pretty-print / sorted keys). `.container` ignores it by design —
    ///     its byte shape is the historical envelope. See `CacheCodec`.
    ///   - ioProfile: write-path profile. `.atomic` (default) is EXACTLY
    ///     the previous behavior — no change for existing callers.
    ///     Use `.durable` when multiple processes may write the same file.
    ///     See ``FileIOProfile`` for per-case guidance.
    public init(
        _ name: String,
        invalidateTime: InvalidateTime = .inTime(ttl: 7 * 24 * 60 * 60),
        baseDirectory: URL,
        envelope: EnvelopeMode = .container,
        naming: FileNaming = .legacy,
        codec: CacheCodec = .default,
        ioProfile: FileIOProfile = .atomic
    ) {
        self.init(
            name, invalidateTime: invalidateTime, envelope: envelope, naming: naming, codec: codec,
            requestedProfile: ioProfile,
            location: .success(LocalFolderCacheBacking(directory: baseDirectory, ioProfile: ioProfile)))
    }

    /// Create a `CacheRepository` whose directory the injected path layer owns:
    /// `paths`' root, then the ``CacheDirectory`` node. The layer must have
    /// ``CacheDirectory`` in its registry; if it cannot resolve it, every
    /// operation throws ``CacheLocationError/unresolvable(cache:reason:)``
    /// naming why — no other folder is tried.
    public init(
        _ name: String,
        invalidateTime: InvalidateTime = .inTime(ttl: 7 * 24 * 60 * 60),
        in paths: any PathResolving,
        envelope: EnvelopeMode = .container,
        naming: FileNaming = .legacy,
        codec: CacheCodec = .default,
        ioProfile: FileIOProfile = .atomic
    ) {
        let location: Result<any SynchronousCacheBacking, CacheLocationError>
        do {
            let directory = try paths.url(for: CacheDirectory())
            location = .success(LocalFolderCacheBacking(directory: directory, ioProfile: ioProfile))
        } catch {
            location = .failure(.unresolvable(cache: name, reason: error.description))
        }
        self.init(
            name, invalidateTime: invalidateTime, envelope: envelope, naming: naming, codec: codec,
            requestedProfile: ioProfile, location: location)
    }

    /// The historical initialiser, whose `baseDirectory` could be left out.
    ///
    /// Left out (or `nil`), the directory used to be the app's documents folder,
    /// a default nobody chose. It now resolves through the ``PathResolving``
    /// registered in the dependency container (``CacheDirectory``), and when
    /// none is registered every operation throws
    /// ``CacheLocationError/noPathLayerRegistered(cache:)`` — never a fallback
    /// folder. A call that passes a real `baseDirectory:` is unchanged, and is
    /// served by the non-deprecated initialiser above.
    @available(*, deprecated, message: """
        Relying on the default cache directory is deprecated. Pass `baseDirectory:` (the directory your path layer resolved),         or `in:` the PathResolving that owns a CacheDirectory. A nil directory now resolves through the PathResolving         registered in DI, and throws CacheLocationError when none is.
        """)
    public init(
        _ name: String,
        invalidateTime: InvalidateTime = .inTime(ttl: 7 * 24 * 60 * 60),
        baseDirectory: URL? = nil,
        envelope: EnvelopeMode = .container,
        naming: FileNaming = .legacy,
        codec: CacheCodec = .default,
        ioProfile: FileIOProfile = .atomic
    ) {
        if let baseDirectory {
            self.init(
                name, invalidateTime: invalidateTime, baseDirectory: baseDirectory, envelope: envelope, naming: naming,
                codec: codec, ioProfile: ioProfile)
        } else if let paths = Container.default.resolveOptional((any PathResolving).self) {
            self.init(
                name, invalidateTime: invalidateTime, in: paths, envelope: envelope, naming: naming, codec: codec,
                ioProfile: ioProfile)
        } else {
            self.init(
                name, invalidateTime: invalidateTime, envelope: envelope, naming: naming, codec: codec,
                requestedProfile: ioProfile, location: .failure(.noPathLayerRegistered(cache: name)))
        }
    }

    /// Create a `CacheRepository` over an injected synchronous backing
    /// (BR-RP-11). There is no default backing here: where the bytes live is
    /// the caller's decision.
    public init(
        _ name: String,
        invalidateTime: InvalidateTime = .inTime(ttl: 7 * 24 * 60 * 60),
        envelope: EnvelopeMode = .container,
        naming: FileNaming = .legacy,
        codec: CacheCodec = .default,
        backing: some SynchronousCacheBacking
    ) {
        self.init(
            name, invalidateTime: invalidateTime, envelope: envelope, naming: naming, codec: codec,
            requestedProfile: backing.fileIOProfile ?? .atomic, location: .success(backing))
    }

    private init(
        _ name: String,
        invalidateTime: InvalidateTime,
        envelope: EnvelopeMode,
        naming: FileNaming,
        codec: CacheCodec,
        requestedProfile: FileIOProfile,
        location: Result<any SynchronousCacheBacking, CacheLocationError>
    ) {
        engine = CacheEntryEngine(
            name: name, invalidateTime: invalidateTime, envelope: envelope, naming: naming, codec: codec)
        self.requestedProfile = requestedProfile
        self.location = location
    }

    // MARK: - CacheRepositoryProtocol

    nonisolated public func exists(_ id: String) -> Bool {
        let entry = engine.entry(for: id)
        do {
            return try backing().contains(entry)
        } catch {
            AppLog.cache.error("Cache exists check failed for \(entry): \(error)")
            return false
        }
    }

    /// Enumerate every record this cache holds (``RepositoryProtocol/list()``).
    /// Scans the backing for this cache's `<name>-<id>.cache` entries and
    /// decodes each container; entries that fail to decode or have expired are
    /// skipped (and logged) rather than failing the whole enumeration.
    nonisolated public func list() throws -> [ModelType] {
        let backing = try backing()
        let names: [String]
        do {
            names = try backing.names()
        } catch {
            AppLog.cache.error("Cache list could not enumerate the backing: \(error)")
            return []
        }
        var out: [ModelType] = []
        for entry in names where engine.isListable(entry) {
            do {
                guard let blob = try backing.read(entry) else { continue }
                if let model = engine.listedModel(from: blob, entry: entry) { out.append(model) }
            } catch {
                AppLog.cache.debug("CacheRepository.list skipped unreadable entry \(entry): \(error)")
            }
        }
        return out
    }

    nonisolated public func get(_ id: String) throws -> ModelType {
        // Synchronous version — only checks TTL, not network status.
        try load(id, hasNetwork: true)
    }

    /// Async version that checks network reachability.
    /// When offline, expired cache is still considered valid for offline support.
    nonisolated public func get(_ id: String, checkNetworkReachability: Bool) async throws -> ModelType {
        let hasNetwork: Bool
        if checkNetworkReachability {
            let interfaceType = await NetworkReachabilityStore.shared.interfaceType
            hasNetwork = interfaceType != nil && interfaceType != .unknown
        } else {
            hasNetwork = true
        }
        return try load(id, hasNetwork: hasNetwork)
    }

    nonisolated public func save(_ id: String, data: ModelType) throws {
        let backing = try backing()
        let entry = engine.entry(for: id)
        do {
            try backing.write(try engine.encode(data), as: entry)
        } catch {
            AppLog.cache.error("Cache save error: \(error)")
            throw CacheRepositoryError.encodedError
        }
    }

    nonisolated public func delete(_ id: String) throws {
        let backing = try backing()
        let entry = engine.entry(for: id)
        let removed: Bool
        do {
            removed = try backing.remove(entry)
        } catch {
            AppLog.cache.warning("Cache delete failed: \(error)")
            throw CacheRepositoryError.deleteError
        }
        guard removed else { throw CacheRepositoryError.notFound }
    }

    // MARK: - Private

    /// The backing, or the named reason there is none.
    nonisolated private func backing() throws(CacheLocationError) -> any SynchronousCacheBacking {
        try location.get()
    }

    nonisolated private func load(_ id: String, hasNetwork: Bool) throws -> ModelType {
        let backing = try backing()
        let entry = engine.entry(for: id)
        let blob: CacheBlob?
        do {
            blob = try backing.read(entry)
        } catch {
            AppLog.cache.error("Cache read failed for \(entry): \(error)")
            throw CacheRepositoryError.notFound
        }
        guard let blob else { throw CacheRepositoryError.notFound }

        switch try engine.decode(blob, hasNetwork: hasNetwork) {
        case .value(let model):
            return model
        case .expired:
            try invalidate(entry, in: backing)
            throw CacheRepositoryError.noCacheAvailable
        }
    }

    nonisolated private func invalidate(_ entry: String, in backing: any SynchronousCacheBacking) throws {
        do {
            // An entry that is already gone satisfies the invalidation.
            _ = try backing.remove(entry)
        } catch {
            AppLog.cache.error("Cache invalidation error: \(error)")
            throw CacheRepositoryError.invalidateCache
        }
    }
}
