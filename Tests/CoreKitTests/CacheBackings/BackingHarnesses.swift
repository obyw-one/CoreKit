import CoreKit
import CoreKitTestSupport
import Foundation

// MARK: - BackingKind

/// Every backing CoreKit ships, each reached through every facade that can
/// carry it — the population the behaviour suite runs over (T-11).
enum BackingKind: String, CaseIterable, Sendable {
    case localFolderSync = "local folder / CacheRepository"
    case localFolderDurableSync = "local folder (durable) / CacheRepository"
    case localFolderAsync = "local folder / AsyncCacheRepository"
    case inMemoryAsync = "in memory / AsyncCacheRepository"
    case objectStoreAsync = "object store / AsyncCacheRepository"
    case s3Async = "S3 client over a fake store / AsyncCacheRepository"

}

// MARK: - BuiltBacking

/// One backing, ready: the two harnesses, and the teardown that removes what it made.
struct BuiltBacking: Sendable {
    let repository: CacheConformanceHarness
    let backing: CacheBackingHarness
    let tearDown: @Sendable () -> Void
    /// What the store itself objected to (a request it would have rejected); empty for stores that cannot.
    let storeObjections: @Sendable () async -> [String]

    init(
        repository: CacheConformanceHarness,
        backing: CacheBackingHarness,
        tearDown: @escaping @Sendable () -> Void,
        storeObjections: @escaping @Sendable () async -> [String] = { [] }
    ) {
        self.repository = repository
        self.backing = backing
        self.tearDown = tearDown
        self.storeObjections = storeObjections
    }
}

struct BackingHarnesses {

    static let bucket: BucketName = "evidence"
    static let node: NodeID = "mac-a"
    static let accessKey = "TESTACCESSKEY"
    static let host = "store.example.test:3900"

    static func build(_ kind: BackingKind) throws -> BuiltBacking {
        switch kind {
        case .localFolderSync: try local(kind, profile: .atomic, asynchronous: false)
        case .localFolderDurableSync: try local(kind, profile: .durable, asynchronous: false)
        case .localFolderAsync: try local(kind, profile: .atomic, asynchronous: true)
        case .inMemoryAsync: inMemory(kind)
        case .objectStoreAsync: objectStore(kind)
        case .s3Async: try s3(kind)
        }
    }

    // MARK: Facades

    static func syncSubject<Model: Codable & Sendable>(
        _ config: CacheConformanceConfig, over backing: some SynchronousCacheBacking
    ) -> ConformanceSubject<Model> {
        let repo = CacheRepository<Model>(
            config.name, invalidateTime: config.invalidateTime, envelope: config.envelope,
            naming: config.naming, codec: config.codec, backing: backing)
        return ConformanceSubject(
            get: { try repo.get($0) }, list: { try repo.list() },
            save: { try repo.save($0, data: $1) }, delete: { try repo.delete($0) }, exists: { repo.exists($0) })
    }

    static func asyncSubject<Model: Codable & Sendable>(
        _ config: CacheConformanceConfig, over backing: some CacheBacking
    ) -> ConformanceSubject<Model> {
        let repo = AsyncCacheRepository<Model>(
            config.name, invalidateTime: config.invalidateTime, envelope: config.envelope,
            naming: config.naming, codec: config.codec, backing: backing)
        return ConformanceSubject(
            get: { try await repo.get($0) }, list: { try await repo.list() },
            save: { try await repo.save($0, data: $1) }, delete: { try await repo.delete($0) },
            exists: { try await repo.exists($0) })
    }

    // MARK: Local folder

    private static func local(_ kind: BackingKind, profile: FileIOProfile, asynchronous: Bool) throws -> BuiltBacking {
        let scratch = TestScratch.forPackage()
        let directory = try scratch.makeScratchDir(scope: "backing-conformance")
        let backing = LocalFolderCacheBacking(directory: directory, ioProfile: profile)

        let age: @Sendable (String, TimeInterval) async throws -> Void = { entry, seconds in
            let url = directory.appending(path: entry, directoryHint: .notDirectory)
            let current = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date ?? Date()
            try FileManager.default.setAttributes(
                [.modificationDate: current.addingTimeInterval(-seconds)], ofItemAtPath: url.path)
        }
        let harness = CacheConformanceHarness(
            label: kind.rawValue,
            makePayloadSubject: { asynchronous ? asyncSubject($0, over: backing) : syncSubject($0, over: backing) },
            makeTextSubject: { asynchronous ? asyncSubject($0, over: backing) : syncSubject($0, over: backing) },
            storedBytes: { try await backing.fetch($0)?.data },
            plant: { try await backing.put($1, as: $0) },
            age: age)
        return BuiltBacking(
            repository: harness,
            backing: CacheBackingHarness(label: kind.rawValue, backing: backing, age: age),
            tearDown: { try? scratch.removeScratchDir(directory) })
    }

    // MARK: In memory

    private static func inMemory(_ kind: BackingKind) -> BuiltBacking {
        let backing = InMemoryCacheBacking()
        let age: @Sendable (String, TimeInterval) async throws -> Void = { entry, seconds in
            guard let current = try await backing.fetch(entry)?.modified else { return }
            await backing.setModified(current.addingTimeInterval(-seconds), for: entry)
        }
        let harness = CacheConformanceHarness(
            label: kind.rawValue,
            makePayloadSubject: { asyncSubject($0, over: backing) },
            makeTextSubject: { asyncSubject($0, over: backing) },
            storedBytes: { try await backing.fetch($0)?.data },
            plant: { try await backing.put($1, as: $0) },
            age: age)
        return BuiltBacking(
            repository: harness,
            backing: CacheBackingHarness(label: kind.rawValue, backing: backing, age: age),
            tearDown: {})
    }

    // MARK: Object store

    private static func objectStore(_ kind: BackingKind) -> BuiltBacking {
        let client = InMemoryObjectStoreClient()
        let backing = ObjectStoreCacheBacking(client: client, bucket: bucket, node: node)
        let age: @Sendable (String, TimeInterval) async throws -> Void = { entry, seconds in
            let key = try backing.address(of: entry).renderedKey()
            guard let current = try await client.get(key: key, in: bucket)?.lastModified else { return }
            await client.setLastModified(current.addingTimeInterval(-seconds), forKey: key, in: bucket)
        }
        let harness = CacheConformanceHarness(
            label: kind.rawValue,
            makePayloadSubject: { asyncSubject($0, over: backing) },
            makeTextSubject: { asyncSubject($0, over: backing) },
            storedBytes: { try await backing.fetch($0)?.data },
            plant: { try await backing.put($1, as: $0) },
            age: age)
        return BuiltBacking(
            repository: harness,
            backing: CacheBackingHarness(label: kind.rawValue, backing: backing, age: age),
            tearDown: {})
    }

    // MARK: S3

    static func s3Client(transport: FakeS3Transport) throws -> S3ObjectStoreClient {
        try S3ObjectStoreClient(
            endpoint: endpoint(), region: "test-region",
            credentials: S3Credentials(accessKey: accessKey, secretKey: "test-secret-never-printed"),
            transport: transport, clock: { Date() })
    }

    static func endpoint() throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "store.example.test"
        components.port = 3900
        return try unwrap(components.url)
    }

    private static func s3(_ kind: BackingKind) throws -> BuiltBacking {
        let transport = FakeS3Transport(accessKey: accessKey, host: host)
        let backing = ObjectStoreCacheBacking(client: try s3Client(transport: transport), bucket: bucket, node: node)
        let age: @Sendable (String, TimeInterval) async throws -> Void = { entry, seconds in
            let key = try backing.address(of: entry).renderedKey()
            guard let current = await transport.modified(bucket: bucket.rawValue, key: key) else { return }
            await transport.setModified(current.addingTimeInterval(-seconds), bucket: bucket.rawValue, key: key)
        }
        let harness = CacheConformanceHarness(
            label: kind.rawValue,
            makePayloadSubject: { asyncSubject($0, over: backing) },
            makeTextSubject: { asyncSubject($0, over: backing) },
            storedBytes: { try await backing.fetch($0)?.data },
            plant: { try await backing.put($1, as: $0) },
            age: age)
        return BuiltBacking(
            repository: harness,
            backing: CacheBackingHarness(label: kind.rawValue, backing: backing, age: age),
            tearDown: {},
            storeObjections: { await transport.violations })
    }

    private init() {}
}

struct MissingValue: Error {}

func unwrap<Value>(_ value: Value?) throws -> Value {
    guard let value else { throw MissingValue() }
    return value
}
