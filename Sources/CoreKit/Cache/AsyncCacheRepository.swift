//
//  AsyncCacheRepository.swift
//  CoreKit
//
//  The cache over a backing that can only answer asynchronously — a database,
//  an object store (spec d3f8a1b2, BR-RP-11).
//

import Foundation

// MARK: - CacheBackingFailure

/// A backing could not do what it was asked — the cause, not a stand-in.
///
/// ``CacheRepository`` folds an I/O failure into its legacy
/// ``CacheRepositoryError`` cases because ~140 call sites already switch on
/// them. ``AsyncCacheRepository`` is new, so it has no such debt: an
/// unreachable database is reported as exactly that, and is never confused with
/// "not found" — a caller that treats a miss as licence to refetch and overwrite
/// must not be told "miss" because the store was down.
public enum CacheBackingFailure: Error, Sendable, CustomStringConvertible, LocalizedError {
    case failed(operation: String, entry: String?, underlying: any Error)

    public var description: String {
        switch self {
        case .failed(let operation, let entry, let underlying):
            "Cache backing \(operation) failed" + (entry.map { " for '\($0)'" } ?? "") + ": \(underlying)"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - AsyncCacheRepository

/// The asynchronous twin of ``CacheRepository``: the SAME envelope, TTL,
/// codec and entry naming, over any ``CacheBacking``.
///
/// It is the `RepositoryProtocol` conformer for a cache whose backing may sit
/// across a network, so a consumer that codes against
/// `any RepositoryProtocol<String, Model>` swaps a local folder for a database
/// or an object store by changing what dependency injection hands it, and
/// nothing else. Because the entry bytes are identical over every backing, an
/// entry written through one is readable through another that holds it.
///
/// There is no default backing: where the bytes live is the caller's decision,
/// injected, never defaulted.
public struct AsyncCacheRepository<T: Codable & Sendable>: RepositoryProtocol {
    public typealias ModelType = T

    private let engine: CacheEntryEngine<T>
    private let backing: any CacheBacking

    public var name: String { engine.name }
    public var envelope: EnvelopeMode { engine.envelope }
    public var naming: FileNaming { engine.naming }
    public var codec: CacheCodec { engine.codec }

    /// - Parameters:
    ///   - name: the cache's name — the stem of every legacy entry name.
    ///   - invalidateTime: TTL policy; see ``InvalidateTime``.
    ///   - envelope: byte shape of an entry; see ``EnvelopeMode``.
    ///   - naming: entry naming; see ``FileNaming``.
    ///   - codec: JSON configuration for `.raw` entries.
    ///   - backing: where the bytes live.
    public init(
        _ name: String,
        invalidateTime: InvalidateTime = .inTime(ttl: 7 * 24 * 60 * 60),
        envelope: EnvelopeMode = .container,
        naming: FileNaming = .legacy,
        codec: CacheCodec = .default,
        backing: some CacheBacking
    ) {
        engine = CacheEntryEngine(
            name: name, invalidateTime: invalidateTime, envelope: envelope, naming: naming, codec: codec)
        self.backing = backing
    }

    // MARK: - RepositoryProtocol

    public func get(_ id: String) async throws -> T {
        try await load(id, hasNetwork: true)
    }

    /// Like ``get(_:)``, consulting network reachability: when offline an
    /// expired entry is still served, so a remote cache keeps working
    /// without a connection.
    public func get(_ id: String, checkNetworkReachability: Bool) async throws -> T {
        let hasNetwork: Bool
        if checkNetworkReachability {
            let interfaceType = await NetworkReachabilityStore.shared.interfaceType
            hasNetwork = interfaceType != nil && interfaceType != .unknown
        } else {
            hasNetwork = true
        }
        return try await load(id, hasNetwork: hasNetwork)
    }

    public func list() async throws -> [T] {
        let names: [String]
        do {
            names = try await backing.entries()
        } catch {
            AppLog.cache.error("Cache list could not enumerate the backing: \(error)")
            throw CacheBackingFailure.failed(operation: "list", entry: nil, underlying: error)
        }
        var out: [T] = []
        for entry in names where engine.isListable(entry) {
            do {
                guard let blob = try await backing.fetch(entry) else { continue }
                if let model = engine.listedModel(from: blob, entry: entry) { out.append(model) }
            } catch {
                // One unreadable entry does not fail the enumeration; it is skipped and said so.
                AppLog.cache.error("AsyncCacheRepository.list skipped unreadable entry \(entry): \(error)")
            }
        }
        return out
    }

    public func save(_ id: String, data: T) async throws {
        let entry = engine.entry(for: id)
        let bytes: Data
        do {
            bytes = try engine.encode(data)
        } catch {
            AppLog.cache.error("Cache save error: \(error)")
            throw CacheRepositoryError.encodedError
        }
        do {
            try await backing.put(bytes, as: entry)
        } catch {
            AppLog.cache.error("Cache save error: \(error)")
            throw CacheBackingFailure.failed(operation: "write", entry: entry, underlying: error)
        }
    }

    public func delete(_ id: String) async throws {
        let entry = engine.entry(for: id)
        let removed: Bool
        do {
            removed = try await backing.delete(entry)
        } catch {
            AppLog.cache.warning("Cache delete failed: \(error)")
            throw CacheBackingFailure.failed(operation: "delete", entry: entry, underlying: error)
        }
        guard removed else { throw CacheRepositoryError.notFound }
    }

    /// Whether an entry is held for `id`. A backing that cannot be reached
    /// throws: absent and unreachable are different answers.
    public func exists(_ id: String) async throws -> Bool {
        let entry = engine.entry(for: id)
        do {
            return try await backing.has(entry)
        } catch {
            throw CacheBackingFailure.failed(operation: "exists", entry: entry, underlying: error)
        }
    }

    // MARK: - Private

    private func load(_ id: String, hasNetwork: Bool) async throws -> T {
        let entry = engine.entry(for: id)
        let blob: CacheBlob?
        do {
            blob = try await backing.fetch(entry)
        } catch {
            AppLog.cache.error("Cache read failed for \(entry): \(error)")
            throw CacheBackingFailure.failed(operation: "read", entry: entry, underlying: error)
        }
        guard let blob else { throw CacheRepositoryError.notFound }

        switch try engine.decode(blob, hasNetwork: hasNetwork) {
        case .value(let model):
            return model
        case .expired:
            do {
                // An entry that is already gone satisfies the invalidation.
                _ = try await backing.delete(entry)
            } catch {
                AppLog.cache.error("Cache invalidation error: \(error)")
                throw CacheBackingFailure.failed(operation: "invalidate", entry: entry, underlying: error)
            }
            throw CacheRepositoryError.noCacheAvailable
        }
    }
}
