import CoreKit
import CoreKitTestSupport
import Foundation
import Testing

// MARK: - FailingBacking

/// A backing that cannot be reached: every verb throws a recognisable error.
private struct FailingBacking: SynchronousCacheBacking {
    struct Unreachable: Error, Equatable {}

    func read(_ entry: String) throws -> CacheBlob? { throw Unreachable() }
    func write(_ data: Data, as entry: String) throws { throw Unreachable() }
    func remove(_ entry: String) throws -> Bool { throw Unreachable() }
    func contains(_ entry: String) throws -> Bool { throw Unreachable() }
    func names() throws -> [String] { throw Unreachable() }
}

private let sample = ConformancePayload(id: 1, name: "sample")

// MARK: - CacheRepositoryBackingTests

@Suite("CacheRepository and AsyncCacheRepository — swappable backing, one contract (BR-RP-11)")
struct CacheRepositoryBackingTests {

    // MARK: One consumer, any backing

    /// Code written once against the protocol — what a consumer that wants to
    /// swap its backing writes.
    private func exercise(_ repository: some RepositoryProtocol<String, ConformancePayload>) async throws -> [ConformancePayload] {
        try await repository.save("a", data: ConformancePayload(id: 1, name: "one"))
        try await repository.save("b", data: ConformancePayload(id: 2, name: "two"))
        try await repository.delete("a")
        return try await repository.list()
    }

    @Test("a consumer coded against RepositoryProtocol is unchanged by the swap")
    func consumerUnchangedBySwap() async throws {
        let scratch = TestScratch.forPackage()
        let directory = try scratch.makeScratchDir(scope: "backing-swap")
        defer { try? scratch.removeScratchDir(directory) }

        let local = CacheRepository<ConformancePayload>("swap", baseDirectory: directory)
        let memory = AsyncCacheRepository<ConformancePayload>("swap", backing: InMemoryCacheBacking())
        let remote = AsyncCacheRepository<ConformancePayload>(
            "swap", backing: ObjectStoreCacheBacking(client: InMemoryObjectStoreClient(), bucket: "evidence", node: "mac-a"))

        let expected = [ConformancePayload(id: 2, name: "two")]
        #expect(try await exercise(local) == expected)
        #expect(try await exercise(memory) == expected)
        #expect(try await exercise(remote) == expected)
    }

    @Test("dependency injection hands the consumer whichever backing was composed")
    func swapThroughTheContainer() async throws {
        func container(_ repository: some RepositoryProtocol<String, ConformancePayload>) throws -> Container {
            let container = Container(name: "swap")
            try container.register((any RepositoryProtocol<String, ConformancePayload>).self, scope: .cached) { _ in repository }
            return container
        }
        let prod = try container(
            AsyncCacheRepository<ConformancePayload>(
                "di", backing: ObjectStoreCacheBacking(client: InMemoryObjectStoreClient(), bucket: "evidence", node: "mac-a")))
        let test = try container(AsyncCacheRepository<ConformancePayload>("di", backing: InMemoryCacheBacking()))
        for composed in [prod, test] {
            let repository = try composed.resolve((any RepositoryProtocol<String, ConformancePayload>).self)
            try await repository.save("k", data: sample)
            #expect(try await repository.get("k") == sample)
        }
    }

    // MARK: Entries are portable

    @Test("an entry written through one facade is readable through the other over the same backing")
    func facadesShareEntries() async throws {
        let scratch = TestScratch.forPackage()
        let directory = try scratch.makeScratchDir(scope: "backing-facades")
        defer { try? scratch.removeScratchDir(directory) }
        let backing = LocalFolderCacheBacking(directory: directory)
        let sync = CacheRepository<ConformancePayload>("shared", invalidateTime: .never, backing: backing)
        let remote = AsyncCacheRepository<ConformancePayload>("shared", invalidateTime: .never, backing: backing)
        try sync.save("from-sync", data: sample)
        try await remote.save("from-async", data: ConformancePayload(id: 2, name: "async"))
        #expect(try await remote.get("from-sync") == sample)
        #expect(try sync.get("from-async") == ConformancePayload(id: 2, name: "async"))
    }

    @Test("moving the bytes from a local folder to an object store keeps every entry readable")
    func migratingLocalToObjectStore() async throws {
        let scratch = TestScratch.forPackage()
        let directory = try scratch.makeScratchDir(scope: "backing-migrate")
        defer { try? scratch.removeScratchDir(directory) }

        let local = LocalFolderCacheBacking(directory: directory)
        let legacy = CacheRepository<ConformancePayload>("Moved", invalidateTime: .never, baseDirectory: directory)
        try legacy.save("one", data: ConformancePayload(id: 1, name: "one"))
        try legacy.save("two", data: ConformancePayload(id: 2, name: "two"))

        let store = ObjectStoreCacheBacking(client: InMemoryObjectStoreClient(), bucket: "evidence", node: "mac-a")
        for entry in try local.names() {
            let blob = try #require(try local.read(entry))
            try await store.put(blob.data, as: entry)
        }
        let remote = AsyncCacheRepository<ConformancePayload>("Moved", invalidateTime: .never, backing: store)
        #expect(try await remote.get("one") == ConformancePayload(id: 1, name: "one"))
        #expect(try await remote.list().count == 2)
    }

    // MARK: Failure is reported, not folded into a miss

    @Test("the async repository reports an unreachable backing as itself, never as not found")
    func asyncReportsFailure() async throws {
        let repository = AsyncCacheRepository<ConformancePayload>("down", backing: FailingBacking())
        await #expect(throws: CacheBackingFailure.self) { _ = try await repository.get("a") }
        await #expect(throws: CacheBackingFailure.self) { try await repository.save("a", data: sample) }
        await #expect(throws: CacheBackingFailure.self) { try await repository.delete("a") }
        await #expect(throws: CacheBackingFailure.self) { _ = try await repository.exists("a") }
        await #expect(throws: CacheBackingFailure.self) { _ = try await repository.list() }
    }

    @Test("the failure carries the operation, the entry and the underlying cause")
    func failureCarriesCause() async throws {
        let repository = AsyncCacheRepository<ConformancePayload>("down", backing: FailingBacking())
        let error = await #expect(throws: CacheBackingFailure.self) { _ = try await repository.get("a") }
        guard case .failed(let operation, let entry, let underlying)? = error else {
            Issue.record("expected a failure, got \(String(describing: error))")
            return
        }
        #expect(operation == "read")
        #expect(entry == "down-a.cache")
        #expect(underlying as? FailingBacking.Unreachable == FailingBacking.Unreachable())
    }

    @Test("the synchronous repository keeps its legacy error cases for the call sites that switch on them")
    func syncKeepsLegacyErrors() throws {
        let repository = CacheRepository<ConformancePayload>("down", backing: FailingBacking())
        #expect(throws: CacheRepositoryError.self) { _ = try repository.get("a") }
        do {
            _ = try repository.get("a")
        } catch {
            #expect(String(describing: error) == String(describing: CacheRepositoryError.notFound))
        }
        do {
            try repository.save("a", data: sample)
        } catch {
            #expect(String(describing: error) == String(describing: CacheRepositoryError.encodedError))
        }
        do {
            try repository.delete("a")
        } catch {
            #expect(String(describing: error) == String(describing: CacheRepositoryError.deleteError))
        }
        #expect(!repository.exists("a"))
        #expect(try repository.list().isEmpty)
    }

    @Test("an id that climbs out of the directory is refused by the repository and writes nothing outside")
    func climbingIdIsRefused() async throws {
        let scratch = TestScratch.forPackage()
        let root = try scratch.makeScratchDir(scope: "backing-climb")
        defer { try? scratch.removeScratchDir(root) }
        let inside = root.appendingPathComponent("inside", isDirectory: true)
        let repository = CacheRepository<ConformancePayload>(
            "climb", invalidateTime: .never, baseDirectory: inside, envelope: .raw, naming: .bareId(ext: "json"))
        let climbing = [PathVocabulary.parentComponent, "outside"].joined(separator: PathVocabulary.wireSeparator)
        do {
            try repository.save(climbing, data: sample)
            Issue.record("a climbing id was written")
        } catch {
            #expect(String(describing: error) == String(describing: CacheRepositoryError.encodedError))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.json").path))
        #expect(!repository.exists(climbing))
    }

    // MARK: Surface

    @Test("the legacy surface is unchanged: name, envelope, naming, codec and profile")
    func legacySurface() {
        let repository = CacheRepository<ConformancePayload>(
            "surface", invalidateTime: .never, baseDirectory: FileManager.default.temporaryDirectory,
            envelope: .raw, naming: .bareId(ext: "json"), codec: .humanReadable, ioProfile: .plain)
        #expect(repository.name == "surface")
        #expect(repository.envelope == .raw)
        #expect(repository.codec == .humanReadable)
        #expect(repository.ioProfile == .plain)
        guard case .bareId(let ext) = repository.naming else {
            Issue.record("naming was not kept")
            return
        }
        #expect(ext == "json")
    }

    @Test("a backing with no file write reports the atomic profile, which is what a save guarantees")
    func memoryProfile() {
        #expect(CacheRepository<ConformancePayload>("m", backing: FailingBacking()).ioProfile == .atomic)
    }

    @Test("both repositories are Sendable without an unchecked escape")
    func sendable() {
        let sync: any Sendable = CacheRepository<ConformancePayload>("s", backing: FailingBacking())
        let remote: any Sendable = AsyncCacheRepository<ConformancePayload>("a", backing: InMemoryCacheBacking())
        _ = (sync, remote)
    }

    // MARK: InMemoryCacheBacking

    @Test("the in-memory backing stamps entries from its injected clock")
    func inMemoryClock() async throws {
        let fixed = Date(timeIntervalSince1970: 1_000_000)
        let backing = InMemoryCacheBacking(clock: { fixed })
        try await backing.put(Data("x".utf8), as: "e")
        #expect(try await backing.fetch("e")?.modified == fixed)
        #expect(await backing.setModified(fixed.addingTimeInterval(-60), for: "e"))
        #expect(try await backing.fetch("e")?.modified == fixed.addingTimeInterval(-60))
        #expect(await !backing.setModified(nil, for: "absent"))
    }

    @Test("the in-memory backing is an actor: concurrent writers need no lock")
    func inMemoryConcurrency() async throws {
        let backing = InMemoryCacheBacking()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask { try await backing.put(Data("\(index)".utf8), as: "e\(index)") }
            }
            try await group.waitForAll()
        }
        #expect(try await backing.entries().count == 200)
    }
}
