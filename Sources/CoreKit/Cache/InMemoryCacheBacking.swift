//
//  InMemoryCacheBacking.swift
//  CoreKit
//

import Foundation

// MARK: - InMemoryCacheBacking

/// Entries held in memory: the backing for tests, for session-scoped caches,
/// and for a consumer that must not touch the disk.
///
/// An actor, so its state needs no lock and no `@unchecked` promise: the
/// compiler proves every access is serialised. It therefore conforms to the
/// asynchronous ``CacheBacking`` only — use it through ``AsyncCacheRepository``.
/// The synchronous ``CacheRepository`` cannot sit on it, and nothing in CoreKit
/// needs that: a synchronous in-memory store would have to block a thread on
/// shared state, which is exactly the lock this type exists to avoid. A caller
/// that wants a synchronous cache without a persistent disk footprint points a
/// ``LocalFolderCacheBacking`` at a scratch directory.
public actor InMemoryCacheBacking: CacheBacking {

    private var storage: [String: CacheBlob] = [:]
    private let clock: @Sendable () -> Date

    /// - Parameter clock: where "modified" comes from; inject a fake to age
    ///   entries deterministically.
    public init(clock: @escaping @Sendable () -> Date) {
        self.clock = clock
    }

    public init() {
        self.init(clock: { Date() })
    }

    public func fetch(_ entry: String) async throws -> CacheBlob? {
        storage[entry]
    }

    public func put(_ data: Data, as entry: String) async throws {
        storage[entry] = CacheBlob(data: data, modified: clock())
    }

    public func delete(_ entry: String) async throws -> Bool {
        storage.removeValue(forKey: entry) != nil
    }

    public func has(_ entry: String) async throws -> Bool {
        storage[entry] != nil
    }

    public func entries() async throws -> [String] {
        Array(storage.keys)
    }

    /// Sets when `entry` was last written — to model an old entry. `false`
    /// when there is no such entry.
    @discardableResult
    public func setModified(_ date: Date?, for entry: String) -> Bool {
        guard let blob = storage[entry] else { return false }
        storage[entry] = CacheBlob(data: blob.data, modified: date)
        return true
    }
}
