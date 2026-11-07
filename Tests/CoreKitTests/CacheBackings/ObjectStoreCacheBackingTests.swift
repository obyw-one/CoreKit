import CoreKit
import Foundation
import Testing

// MARK: - ObjectStoreCacheBackingTests

@Suite("ObjectStoreCacheBacking — bucket, node id, entry (BR-RP-07, T-06)")
struct ObjectStoreCacheBackingTests {

    private static let separator = PathVocabulary.wireSeparator
    private static let bucket: BucketName = "evidence"

    private func backing(_ client: any ObjectStoreClient, node: NodeID) -> ObjectStoreCacheBacking {
        ObjectStoreCacheBacking(client: client, bucket: Self.bucket, node: node)
    }

    @Test("T-06: three node ids writing one entry never collide")
    func threeNodesNeverCollide() async throws {
        let client = InMemoryObjectStoreClient()
        let nodes: [NodeID] = ["mac-a", "mac-b", "mac-c"]
        let backings = nodes.map { backing(client, node: $0) }
        for (index, backing) in backings.enumerated() {
            try await backing.put(Data("from-\(index)".utf8), as: "wave-1.json")
        }
        for (index, backing) in backings.enumerated() {
            #expect(try await backing.fetch("wave-1.json")?.data == Data("from-\(index)".utf8), "node \(index) was overwritten")
        }
        let keys = try await client.keys(withPrefix: "", in: Self.bucket)
        #expect(Set(keys).count == 3)
        #expect(Set(keys) == Set(nodes.map { $0.description + Self.separator + "wave-1.json" }))
    }

    @Test("T-06: three nodes writing through the real S3 client do not collide either")
    func threeNodesThroughS3() async throws {
        let transport = FakeS3Transport(accessKey: BackingHarnesses.accessKey, host: BackingHarnesses.host)
        let client = try BackingHarnesses.s3Client(transport: transport)
        let nodes: [NodeID] = ["mac-a", "mac-b", "mac-c"]
        for node in nodes {
            try await ObjectStoreCacheBacking(client: client, bucket: BackingHarnesses.bucket, node: node)
                .put(Data(node.description.utf8), as: "wave-1.json")
        }
        #expect(await transport.storedKeys(bucket: BackingHarnesses.bucket.rawValue).count == 3)
        #expect(await transport.violations.isEmpty)
    }

    @Test("a node lists and deletes only its own entries; a longer node id is not a prefix match")
    func nodeIsolation() async throws {
        let client = InMemoryObjectStoreClient()
        let short = backing(client, node: "mac-a")
        let long = backing(client, node: "mac-ab")
        try await short.put(Data("s".utf8), as: "one")
        try await long.put(Data("l".utf8), as: "two")
        #expect(try await short.entries() == ["one"])
        #expect(try await long.entries() == ["two"])
        #expect(try await !short.delete("two"), "node mac-a deleted node mac-ab's entry")
        #expect(try await long.has("two"))
    }

    @Test("scoped(to:) reads what another node wrote: the consolidation view")
    func scopedReadsAnotherNode() async throws {
        let client = InMemoryObjectStoreClient()
        let writer = backing(client, node: "mac-b")
        try await writer.put(Data("evidence".utf8), as: "wave-2.json")
        let consolidator = backing(client, node: "mac-a").scoped(to: "mac-b")
        #expect(consolidator.node == "mac-b")
        #expect(try await consolidator.fetch("wave-2.json")?.data == Data("evidence".utf8))
        #expect(try await backing(client, node: "mac-a").fetch("wave-2.json") == nil)
    }

    @Test("the address of an entry is the owner's address: bucket, node, then the entry")
    func addressShape() throws {
        let address = try backing(InMemoryObjectStoreClient(), node: "mac-a").address(of: "wave-1.json")
        #expect(address.rendered() == ["evidence", "mac-a", "wave-1.json"].joined(separator: Self.separator))
        #expect(address.node == "mac-a")
    }

    @Test("nested entry names are legal keys and list back as written")
    func nestedEntries() async throws {
        let client = InMemoryObjectStoreClient()
        let store = backing(client, node: "mac-a")
        let nested = ["flows", "7f3a", "metadata.json"].joined(separator: Self.separator)
        try await store.put(Data("n".utf8), as: nested)
        #expect(try await store.entries() == [nested])
        #expect(try await store.fetch(nested)?.data == Data("n".utf8))
    }

    @Test("an entry that would climb or that a store cannot carry is refused, not written elsewhere",
          arguments: ObjectStoreCacheBackingTests.refusedEntries)
    func refusedEntryNames(_ entry: String) async throws {
        let client = InMemoryObjectStoreClient()
        let store = backing(client, node: "mac-a")
        await #expect(throws: CacheBackingError.self) { try await store.put(Data("x".utf8), as: entry) }
        await #expect(throws: CacheBackingError.self) { _ = try await store.fetch(entry) }
        #expect(try await client.keys(withPrefix: "", in: Self.bucket).isEmpty, "a refused entry still wrote an object")
    }

    private static let refusedEntries: [String] = [
        ["a", PathVocabulary.parentComponent, "b"].joined(separator: separator),
        PathVocabulary.parentComponent,
        ["a", "", "b"].joined(separator: separator),
        "has:colon",
        "has?query",
        "",
    ]

    @Test("the refusal names the entry and the reason")
    func refusalMessage() async throws {
        let store = backing(InMemoryObjectStoreClient(), node: "mac-a")
        let climbing = [PathVocabulary.parentComponent, "x"].joined(separator: Self.separator)
        let error = await #expect(throws: CacheBackingError.self) { _ = try await store.fetch(climbing) }
        guard case .invalidEntryName(let entry, let reason)? = error else {
            Issue.record("expected invalidEntryName, got \(String(describing: error))")
            return
        }
        #expect(entry == climbing)
        #expect(!reason.isEmpty)
    }

    @Test("no file write profile applies to an object store")
    func noFileProfile() {
        #expect(backing(InMemoryObjectStoreClient(), node: "mac-a").fileIOProfile == nil)
    }
}
