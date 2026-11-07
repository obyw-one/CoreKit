//
//  OwnedResourceStore.swift
//  CoreKit
//
//  The attachment point between an owner and the cache layer (spec d3f8a1b2,
//  BR-RP-02/11): a typed owner, the path layer that resolves it, and
//  `CacheRepository` to read and write it. A redesign of ShiKit's
//  `FileResourceStore` / `FileResourceStoreProtocol`, generic over any owner
//  and any project.
//

import Foundation

// MARK: - ResourceStoreError

/// Why a resource could not be read, written or removed. Names the resource
/// by its file name, never its full path, so the message is safe in a log.
public enum ResourceStoreError: Error, Sendable, CustomStringConvertible {
    /// The resource exists but could not be read.
    case readFailed(resource: String, underlying: any Error)
    /// The resource was read but is not a valid `Model`.
    case decodeFailed(resource: String, underlying: any Error)
    /// The resource could not be written (encode, create the directory, or I/O).
    case writeFailed(resource: String, underlying: any Error)
    /// The resource could not be removed.
    case deleteFailed(resource: String, underlying: any Error)

    public var description: String {
        switch self {
        case .readFailed(let resource, let underlying):
            "ResourceStore: reading \(resource) failed — \(underlying)"
        case .decodeFailed(let resource, let underlying):
            "ResourceStore: \(resource) is not a valid document — \(underlying)"
        case .writeFailed(let resource, let underlying):
            "ResourceStore: writing \(resource) failed — \(underlying)"
        case .deleteFailed(let resource, let underlying):
            "ResourceStore: removing \(resource) failed — \(underlying)"
        }
    }
}

// MARK: - ResourceStoring

/// ONE typed document: load it, save it, delete it. The document is the
/// store's identity (the owner it was built for), so there is no key to pass —
/// and a reader and a writer of the same owner cannot disagree about the model.
///
/// Missing is not an error: ``load()`` returns `nil` for a document that was
/// never written, and ``delete()`` of an absent one is a no-op.
///
/// Async, so a store whose state is an actor (``InMemoryResourceStore``) can
/// conform without a lock. ``OwnedResourceStore`` is plain file I/O and keeps
/// its synchronous methods, which satisfy the async requirements: code that
/// holds the concrete type calls it without `await`, code coded against the
/// protocol awaits.
public protocol ResourceStoring<Model>: Sendable {
    associatedtype Model: Codable & Sendable

    func load() async throws -> Model?
    func save(_ model: Model) async throws
    func delete() async throws
    func exists() async -> Bool
}

// MARK: - OwnedResourceStore

/// A document on disk at the location its owner declares.
///
/// The location comes from the injected ``PathResolving`` (so prod and test
/// differ only by the root), and the I/O is CoreKit's own ``CacheRepository``:
/// a `.raw` entry — the file IS the model's JSON, `cat`-able and `jq`-able —
/// with the human-readable codec, no expiry (a document is not a cache entry),
/// and the write profile passed straight through, so `.durable` is CoreKit's
/// real cross-process guarantee and not a reimplementation.
///
/// Resolution creates nothing: building the store, ``url`` and ``load()`` never
/// touch the disk beyond reading. The directory is created by the first
/// ``save(_:)`` — the writer creates it.
public struct OwnedResourceStore<Model: Codable & Sendable>: ResourceStoring {

    /// The resolved file location of the document.
    public let url: URL

    private let ioProfile: FileIOProfile

    /// - Parameters:
    ///   - owner: the typed owner that declares where the document lives.
    ///   - paths: the injected path layer.
    ///   - ioProfile: the write profile; see ``FileIOProfile``.
    public init<Owner: VirtualPathOwning>(
        _ owner: Owner, paths: any PathResolving, ioProfile: FileIOProfile = .atomic
    ) throws(VirtualPathError) {
        url = try paths.url(for: owner)
        self.ioProfile = ioProfile
    }

    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func load() throws -> Model? {
        guard exists() else { return nil }
        do {
            return try repository().get(Self.key)
        } catch CacheRepositoryError.notFound {
            return nil
        } catch CacheRepositoryError.decodedError {
            throw ResourceStoreError.decodeFailed(resource: url.lastPathComponent, underlying: CacheRepositoryError.decodedError)
        } catch {
            throw ResourceStoreError.readFailed(resource: url.lastPathComponent, underlying: error)
        }
    }

    public func save(_ model: Model) throws {
        do {
            try repository().save(Self.key, data: model)
        } catch {
            throw ResourceStoreError.writeFailed(resource: url.lastPathComponent, underlying: error)
        }
    }

    public func delete() throws {
        guard exists() else { return }
        do {
            try repository().delete(Self.key)
        } catch {
            throw ResourceStoreError.deleteFailed(resource: url.lastPathComponent, underlying: error)
        }
    }

    // MARK: - Private

    /// The one entry the store holds; the file name is pinned to the resolved location.
    private static var key: String { "resource" }

    /// Built on demand: constructing a cache creates its directory, and a read
    /// must not.
    private func repository() -> CacheRepository<Model> {
        let fileName = url.lastPathComponent
        return CacheRepository<Model>(
            "resource-store",
            invalidateTime: .never,
            baseDirectory: url.deletingLastPathComponent(),
            envelope: .raw,
            naming: .custom { _, _ in fileName },
            codec: .humanReadable,
            ioProfile: ioProfile)
    }
}

// MARK: - InMemoryResourceStore

/// A document held in memory: the test double for ``ResourceStoring``, so a
/// test never touches a disk and never needs a resolver for a store it only
/// stubs.
///
/// An actor: its one mutable value is serialised by the compiler, with no lock
/// and no `@unchecked` promise.
public actor InMemoryResourceStore<Model: Codable & Sendable>: ResourceStoring {

    private var stored: Model?

    public init(initial: Model? = nil) {
        stored = initial
    }

    public func load() async throws -> Model? { stored }
    public func save(_ model: Model) async throws { stored = model }
    public func delete() async throws { stored = nil }
    public func exists() async -> Bool { stored != nil }
}
