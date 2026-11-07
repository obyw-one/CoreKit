//
//  CacheBacking.swift
//  CoreKit
//
//  The storage a cache sits on, behind one protocol (spec d3f8a1b2, BR-RP-11).
//

import Foundation

// MARK: - CacheBlob

/// What a backing returns for one entry: the stored bytes and, where the
/// backing knows it, when they were last written.
///
/// `modified` is what TTL reads for the `.raw` and `.rawString` envelopes
/// (their payload is the model itself, so the timestamp cannot live inside it).
/// A backing that cannot tell returns `nil`, and the cache treats the entry as
/// fresh rather than destroy readable data on a guess.
public struct CacheBlob: Sendable, Equatable {
    public let data: Data
    public let modified: Date?

    public init(data: Data, modified: Date?) {
        self.data = data
        self.modified = modified
    }
}

// MARK: - CacheBackingError

/// Why a backing refused an entry. I/O failures are the backing's own errors,
/// thrown as they are; these are the refusals the contract itself defines.
public enum CacheBackingError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// The entry name resolves outside the backing's location (a `..` climb,
    /// or a symlink that leaves it).
    case entryEscapesLocation(entry: String)
    /// The backing cannot address this entry name (an object store refuses a
    /// name that is not a valid key path).
    case invalidEntryName(entry: String, reason: String)
    /// A system call on the entry failed.
    case ioFailed(operation: String, entry: String, errnoCode: Int32)

    public var description: String {
        switch self {
        case .entryEscapesLocation(let entry):
            "CacheBacking: entry '\(entry)' resolves outside the cache location"
        case .invalidEntryName(let entry, let reason):
            "CacheBacking: entry '\(entry)' cannot be addressed — \(reason)"
        case .ioFailed(let operation, let entry, let errnoCode):
            "CacheBacking: \(operation) failed for '\(entry)' (errno \(errnoCode))"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - CacheBacking

/// Bytes in, bytes out, by entry name — the ONE protocol a cache's storage
/// implements, whatever it is: a folder, memory, a database table, an object
/// store (BR-RP-11).
///
/// A backing knows nothing of models, envelopes, TTL or file naming: those are
/// the cache's, identical over every backing, which is what makes the same
/// consumer code behave the same when the backing is swapped. The backing owns
/// WHERE (a directory, a bucket and node, a table) and HOW the bytes are
/// committed.
///
/// Async-first, because a database or an object store can only be: a backing
/// that is naturally synchronous also conforms to ``SynchronousCacheBacking``.
/// An entry that is absent is `nil` / `false`, never an error; every other
/// failure is thrown with its cause.
public protocol CacheBacking: Sendable {

    /// The bytes held under `entry`, or `nil` when there are none.
    func fetch(_ entry: String) async throws -> CacheBlob?

    /// Stores `data` under `entry`, replacing what was there. All-or-nothing: a
    /// reader never sees half of a write.
    func put(_ data: Data, as entry: String) async throws

    /// Removes `entry`. `true` when there was something to remove.
    func delete(_ entry: String) async throws -> Bool

    /// Whether `entry` is held.
    func has(_ entry: String) async throws -> Bool

    /// Every entry held, in no particular order. Names the backing keeps for
    /// its own bookkeeping (lock files, temporary files) are not entries.
    func entries() async throws -> [String]

    /// The file write profile this backing honours, or `nil` when the notion
    /// does not apply (a database transaction and an object put are atomic by
    /// construction).
    var fileIOProfile: FileIOProfile? { get }
}

extension CacheBacking {
    public var fileIOProfile: FileIOProfile? { nil }
}

// MARK: - SynchronousCacheBacking

/// A backing that can answer without suspending — a local folder.
///
/// ``CacheRepository``, whose API is synchronous across about 140 call
/// sites, accepts only these: a synchronous call on an async-only backing would
/// have to block a thread on the network, so the type system does not let it
/// be written. An async-only backing is used through ``AsyncCacheRepository``.
public protocol SynchronousCacheBacking: CacheBacking {
    func read(_ entry: String) throws -> CacheBlob?
    func write(_ data: Data, as entry: String) throws
    func remove(_ entry: String) throws -> Bool
    func contains(_ entry: String) throws -> Bool
    func names() throws -> [String]
}

extension SynchronousCacheBacking {
    public func fetch(_ entry: String) async throws -> CacheBlob? { try read(entry) }
    public func put(_ data: Data, as entry: String) async throws { try write(data, as: entry) }
    public func delete(_ entry: String) async throws -> Bool { try remove(entry) }
    public func has(_ entry: String) async throws -> Bool { try contains(entry) }
    public func entries() async throws -> [String] { try names() }
}
