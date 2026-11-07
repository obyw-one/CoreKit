import CoreKit
import CoreKitTestSupport
import Foundation
import Testing

// MARK: - Fixtures

private struct Ledger: Codable, Sendable, Equatable {
    let revision: Int
    let note: String
    let stamped: Date
}

private enum Tree {
    static let state = VirtualNode("state")
    static let flows = VirtualNode("flows")
}

private struct LedgerFile: VirtualPathOwning {
    static let placement = VirtualPlacement(node: Tree.state, name: "ledger.json")
}

private struct FlowLedger: VirtualPathOwning {
    static let placement = VirtualPlacement(node: Tree.flows, name: "ledger.json")
    let flowID: String

    func location() throws(VirtualPathError) -> VirtualPath {
        VirtualPath(try PathSegment(flowID), try PathSegment("\(flowID)-ledger.json"))
    }
}

private struct Unregistered: VirtualPathOwning {
    static let placement = VirtualPlacement(node: Tree.state, name: "unregistered.json")
}

private let sample = Ledger(revision: 3, note: "kept — é", stamped: Date(timeIntervalSince1970: 1_700_000_000))

private struct Sandbox {
    let scratch = TestScratch.forPackage()
    let root: URL
    let paths: PathLayer

    init() throws {
        root = try scratch.makeScratchDir(scope: "owned-resource-store")
        paths = try PathLayer(root: root, registry: VirtualPathRegistry([LedgerFile.self, FlowLedger.self]))
    }

    func sweep() { try? scratch.removeScratchDir(root) }
}

// MARK: - OwnedResourceStoreTests

@Suite("OwnedResourceStore — an owner, a resolver and the cache layer (BR-RP-02, BR-RP-11)")
struct OwnedResourceStoreTests {

    @Test("save then load round-trips at the location the owner declares")
    func roundTrip() throws {
        let box = try Sandbox()
        defer { box.sweep() }
        let store = try OwnedResourceStore<Ledger>(LedgerFile(), paths: box.paths)
        try store.save(sample)
        #expect(try store.load() == sample)
        #expect(store.exists())
        #expect(store.url == (try box.paths.url(for: LedgerFile())))
        #expect(FileManager.default.fileExists(atPath: store.url.path))
        #expect(PathContainment.isContained(store.url, in: box.root))
    }

    @Test("the file IS the model's JSON: readable as it is, with sorted keys and ISO dates")
    func fileIsReadableJSON() throws {
        let box = try Sandbox()
        defer { box.sweep() }
        let store = try OwnedResourceStore<Ledger>(LedgerFile(), paths: box.paths)
        try store.save(sample)
        let bytes = try Data(contentsOf: store.url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Ledger.self, from: bytes) == sample)
        let text = try #require(String(bytes: bytes, encoding: .utf8))
        #expect(text.contains("2023-11-14T22:13:20Z"), "dates are ISO-8601 strings")
        let note = try #require(text.range(of: "\"note\""))
        let revision = try #require(text.range(of: "\"revision\""))
        #expect(note.lowerBound < revision.lowerBound, "keys are sorted")
    }

    @Test("missing is not an error: load is nil, delete is a no-op, and nothing is created")
    func missingIsNotAnError() throws {
        let box = try Sandbox()
        defer { box.sweep() }
        let store = try OwnedResourceStore<Ledger>(LedgerFile(), paths: box.paths)
        #expect(try store.load() == nil)
        #expect(!store.exists())
        try store.delete()
        #expect(!FileManager.default.fileExists(atPath: store.url.deletingLastPathComponent().path),
                "reading or deleting an absent document created its directory")
    }

    @Test("the writer creates the directory: the first save does")
    func writerCreatesTheDirectory() throws {
        let box = try Sandbox()
        defer { box.sweep() }
        let store = try OwnedResourceStore<Ledger>(LedgerFile(), paths: box.paths)
        #expect(!FileManager.default.fileExists(atPath: store.url.deletingLastPathComponent().path))
        try store.save(sample)
        #expect(FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test("delete removes the document")
    func deleteRemoves() throws {
        let box = try Sandbox()
        defer { box.sweep() }
        let store = try OwnedResourceStore<Ledger>(LedgerFile(), paths: box.paths)
        try store.save(sample)
        try store.delete()
        #expect(!store.exists())
        #expect(try store.load() == nil)
    }

    @Test("a save replaces the previous document")
    func saveReplaces() throws {
        let box = try Sandbox()
        defer { box.sweep() }
        let store = try OwnedResourceStore<Ledger>(LedgerFile(), paths: box.paths)
        try store.save(sample)
        let next = Ledger(revision: 4, note: "next", stamped: sample.stamped)
        try store.save(next)
        #expect(try store.load() == next)
    }

    @Test("a file that is not a Model is a decode failure naming the file, not a nil")
    func corruptFile() throws {
        let box = try Sandbox()
        defer { box.sweep() }
        let store = try OwnedResourceStore<Ledger>(LedgerFile(), paths: box.paths)
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: store.url)
        let error = #expect(throws: ResourceStoreError.self) { _ = try store.load() }
        guard case .decodeFailed(let resource, _)? = error else {
            Issue.record("expected decodeFailed, got \(String(describing: error))")
            return
        }
        #expect(resource == "ledger.json")
        #expect(!String(describing: error).contains(box.root.path), "the message must not carry the full local path")
    }

    @Test("an id-dependent owner stores under its id folder")
    func idDependentOwner() throws {
        let box = try Sandbox()
        defer { box.sweep() }
        let store = try OwnedResourceStore<Ledger>(FlowLedger(flowID: "7f3a"), paths: box.paths)
        try store.save(sample)
        #expect(store.url.lastPathComponent == "7f3a-ledger.json")
        #expect(store.url.deletingLastPathComponent().lastPathComponent == "7f3a")
        let other = try OwnedResourceStore<Ledger>(FlowLedger(flowID: "9c1d"), paths: box.paths)
        #expect(try other.load() == nil, "two ids share a document")
    }

    @Test("a hostile id never becomes a store")
    func hostileIdRefused() throws {
        let box = try Sandbox()
        defer { box.sweep() }
        let climbing = [PathVocabulary.parentComponent, "x"].joined(separator: PathVocabulary.wireSeparator)
        #expect(throws: VirtualPathError.self) {
            try OwnedResourceStore<Ledger>(FlowLedger(flowID: climbing), paths: box.paths)
        }
    }

    @Test("an owner never added to the tree cannot be stored")
    func unregisteredOwnerRefused() throws {
        let box = try Sandbox()
        defer { box.sweep() }
        #expect(throws: VirtualPathError.self) { try OwnedResourceStore<Ledger>(Unregistered(), paths: box.paths) }
    }

    @Test("prod and test stores of one owner differ only by the root")
    func prodAndTestDifferOnlyByRoot() throws {
        let box = try Sandbox()
        defer { box.sweep() }
        let run = try TestRunRoot(base: box.root, branch: "main", correlationID: "corr-1", target: "CoreKitTests")
        let test = try PathLayer(root: run.url, registry: VirtualPathRegistry([LedgerFile.self]))
        let prodStore = try OwnedResourceStore<Ledger>(LedgerFile(), paths: box.paths)
        let testStore = try OwnedResourceStore<Ledger>(LedgerFile(), paths: test)
        try prodStore.save(sample)
        #expect(try testStore.load() == nil, "the test root sees the production document")
        #expect(prodStore.url != testStore.url)
        #expect(prodStore.url.lastPathComponent == testStore.url.lastPathComponent)
    }

    @Test("the durable profile is honoured and leaves no temp file behind")
    func durableProfile() throws {
        let box = try Sandbox()
        defer { box.sweep() }
        let store = try OwnedResourceStore<Ledger>(LedgerFile(), paths: box.paths, ioProfile: .durable)
        try store.save(sample)
        #expect(try store.load() == sample)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path)
        #expect(!names.contains { $0.contains(".tmp") }, "a temp file survived the durable write: \(names)")
    }

    // MARK: ResourceStoring

    private func exercise(_ store: some ResourceStoring<Ledger>) async throws -> [Ledger?] {
        var seen: [Ledger?] = [try await store.load()]
        try await store.save(sample)
        seen.append(try await store.load())
        try await store.delete()
        seen.append(try await store.load())
        return seen
    }

    @Test("code written against ResourceStoring behaves the same over the file store and the double")
    func sameOverBoth() async throws {
        let box = try Sandbox()
        defer { box.sweep() }
        let file = try await exercise(OwnedResourceStore<Ledger>(LedgerFile(), paths: box.paths))
        let memory = try await exercise(InMemoryResourceStore<Ledger>())
        #expect(file == [nil, sample, nil])
        #expect(memory == file)
    }

    @Test("the in-memory double honours an initial document and reports existence")
    func inMemoryDouble() async throws {
        let store = InMemoryResourceStore(initial: sample)
        #expect(await store.exists())
        #expect(try await store.load() == sample)
        try await store.delete()
        #expect(await !store.exists())
    }
}
