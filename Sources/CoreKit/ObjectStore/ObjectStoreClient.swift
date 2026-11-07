//
//  ObjectStoreClient.swift
//  CoreKit
//
//  The five verbs of an S3-compatible object store, as a protocol (spec
//  d3f8a1b2, BR-RP-07/11). Nothing here names a vendor: a self-hosted
//  Garage, MinIO or any other compatible store is another conformer.
//

import Foundation

// MARK: - ObjectStoreObject

/// One object as a store returns it.
public struct ObjectStoreObject: Sendable, Equatable {
    public let data: Data
    /// The store's last-modified time, when it reports one.
    public let lastModified: Date?

    public init(data: Data, lastModified: Date?) {
        self.data = data
        self.lastModified = lastModified
    }
}

// MARK: - ObjectStoreClient

/// Put, get, exists, delete and list by `bucket` + key.
///
/// Keys are strings the store sees below the bucket — for the fleet, the
/// ``ResourceAddress/renderedKey(separator:)`` of a node-scoped address. A
/// client never invents a key and never defaults a bucket or an endpoint.
public protocol ObjectStoreClient: Sendable {

    /// Stores `data` under `key`, replacing any object there.
    func put(_ data: Data, key: String, in bucket: BucketName) async throws

    /// The object under `key`, or `nil` when there is none.
    func get(key: String, in bucket: BucketName) async throws -> ObjectStoreObject?

    /// Whether an object is held under `key`.
    func exists(key: String, in bucket: BucketName) async throws -> Bool

    /// Removes the object under `key`. Like the S3 verb it models, it does not
    /// fail when there was nothing to remove — callers that must know ask
    /// ``exists(key:in:)`` first.
    func delete(key: String, in bucket: BucketName) async throws

    /// Every key in `bucket` that begins with `prefix`, in no particular order.
    func keys(withPrefix prefix: String, in bucket: BucketName) async throws -> [String]
}

// MARK: - InMemoryObjectStoreClient

/// An object store in memory: the double for tests and the reference for the
/// semantics every client must match. An actor, so concurrent writers from
/// several tasks are safe without a lock.
public actor InMemoryObjectStoreClient: ObjectStoreClient {

    private struct Slot: Hashable {
        let bucket: BucketName
        let key: String
    }

    private var objects: [Slot: ObjectStoreObject] = [:]
    private let clock: @Sendable () -> Date

    /// - Parameter clock: where last-modified comes from; inject a fake to age objects.
    public init(clock: @escaping @Sendable () -> Date) {
        self.clock = clock
    }

    public init() {
        self.init(clock: { Date() })
    }

    public func put(_ data: Data, key: String, in bucket: BucketName) async throws {
        objects[Slot(bucket: bucket, key: key)] = ObjectStoreObject(data: data, lastModified: clock())
    }

    public func get(key: String, in bucket: BucketName) async throws -> ObjectStoreObject? {
        objects[Slot(bucket: bucket, key: key)]
    }

    public func exists(key: String, in bucket: BucketName) async throws -> Bool {
        objects[Slot(bucket: bucket, key: key)] != nil
    }

    public func delete(key: String, in bucket: BucketName) async throws {
        objects.removeValue(forKey: Slot(bucket: bucket, key: key))
    }

    public func keys(withPrefix prefix: String, in bucket: BucketName) async throws -> [String] {
        objects.keys.filter { $0.bucket == bucket && $0.key.hasPrefix(prefix) }.map(\.key)
    }

    /// Sets when the object under `key` was last written — to model an old object.
    /// `false` when there is no such object.
    @discardableResult
    public func setLastModified(_ date: Date?, forKey key: String, in bucket: BucketName) -> Bool {
        let slot = Slot(bucket: bucket, key: key)
        guard let object = objects[slot] else { return false }
        objects[slot] = ObjectStoreObject(data: object.data, lastModified: date)
        return true
    }
}

// MARK: - ObjectStoreCacheBacking

/// A ``CacheBacking`` over an object store, addressed `bucket` + node + entry
/// (BR-RP-07, BR-RP-11).
///
/// Every entry's key leads with the NODE ID: `<node>/<entry>`. Three Macs
/// working one spec write the same logical entry to three different keys, so
/// the last writer cannot silently erase the others, and a consolidation step
/// can read every node's rows by name. The node is part of the backing's
/// identity, not a convention its callers remember.
///
/// The entry name is validated as a key path (``VirtualPath``): an entry that
/// would climb, or carries a character a compatible store cannot, is refused
/// with ``CacheBackingError/invalidEntryName(entry:reason:)`` instead of being
/// written somewhere unintended. Nested names (`a` + separator + `b`) are
/// legal keys.
public struct ObjectStoreCacheBacking: CacheBacking {

    public let client: any ObjectStoreClient
    public let bucket: BucketName
    public let node: NodeID

    public init(client: any ObjectStoreClient, bucket: BucketName, node: NodeID) {
        self.client = client
        self.bucket = bucket
        self.node = node
    }

    /// The same store and bucket seen as another node — how a consolidation
    /// step reads the evidence every node wrote.
    public func scoped(to node: NodeID) -> ObjectStoreCacheBacking {
        ObjectStoreCacheBacking(client: client, bucket: bucket, node: node)
    }

    /// The object-store address of `entry`, as this node writes it.
    public func address(of entry: String) throws -> ResourceAddress {
        let path: VirtualPath
        do {
            path = try VirtualPath(parsing: entry)
        } catch {
            throw CacheBackingError.invalidEntryName(entry: entry, reason: error.description)
        }
        // The empty path would address the node itself, not an entry.
        guard !path.isEmpty else {
            throw CacheBackingError.invalidEntryName(entry: entry, reason: "an entry name cannot be empty")
        }
        return ResourceAddress(bucket: bucket, node: node, path: path)
    }

    // MARK: CacheBacking

    public func fetch(_ entry: String) async throws -> CacheBlob? {
        let key = try address(of: entry).renderedKey()
        guard let object = try await client.get(key: key, in: bucket) else { return nil }
        return CacheBlob(data: object.data, modified: object.lastModified)
    }

    public func put(_ data: Data, as entry: String) async throws {
        try await client.put(data, key: try address(of: entry).renderedKey(), in: bucket)
    }

    public func delete(_ entry: String) async throws -> Bool {
        let key = try address(of: entry).renderedKey()
        guard try await client.exists(key: key, in: bucket) else { return false }
        try await client.delete(key: key, in: bucket)
        return true
    }

    public func has(_ entry: String) async throws -> Bool {
        try await client.exists(key: try address(of: entry).renderedKey(), in: bucket)
    }

    public func entries() async throws -> [String] {
        // The trailing separator keeps node `mac-a` from listing node `mac-ab`.
        let prefix = VirtualPath(node.segment).rendered() + PathVocabulary.wireSeparator
        return try await client.keys(withPrefix: prefix, in: bucket).map { String($0.dropFirst(prefix.count)) }
    }
}
