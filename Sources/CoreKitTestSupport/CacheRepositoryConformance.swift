import CoreKit
import Foundation

// MARK: - ConformancePayload

/// The model every conformance check stores.
public struct ConformancePayload: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

// MARK: - CacheConformanceConfig

/// The cache a check asks the harness to build.
public struct CacheConformanceConfig: Sendable {
    public var name: String
    public var invalidateTime: InvalidateTime
    public var envelope: EnvelopeMode
    public var naming: FileNaming
    public var codec: CacheCodec

    public init(
        name: String,
        invalidateTime: InvalidateTime = .inTime(ttl: 3600),
        envelope: EnvelopeMode = .container,
        naming: FileNaming = .legacy,
        codec: CacheCodec = .default
    ) {
        self.name = name
        self.invalidateTime = invalidateTime
        self.envelope = envelope
        self.naming = naming
        self.codec = codec
    }
}

// MARK: - ConformanceSubject

/// One cache under test, reduced to the verbs every cache facade shares, so
/// ONE behaviour suite runs over `CacheRepository` and `AsyncCacheRepository`
/// and over every backing beneath them.
public struct ConformanceSubject<Model: Sendable>: Sendable {
    public let get: @Sendable (String) async throws -> Model
    public let list: @Sendable () async throws -> [Model]
    public let save: @Sendable (String, Model) async throws -> Void
    public let delete: @Sendable (String) async throws -> Void
    public let exists: @Sendable (String) async throws -> Bool

    public init(
        get: @escaping @Sendable (String) async throws -> Model,
        list: @escaping @Sendable () async throws -> [Model],
        save: @escaping @Sendable (String, Model) async throws -> Void,
        delete: @escaping @Sendable (String) async throws -> Void,
        exists: @escaping @Sendable (String) async throws -> Bool
    ) {
        self.get = get
        self.list = list
        self.save = save
        self.delete = delete
        self.exists = exists
    }
}

// MARK: - CacheConformanceHarness

/// A backing wired for the suite: how to build a cache over it, and the three
/// things the suite must do to the storage behind the cache's back — read the
/// bytes it holds, plant bytes, and make an entry older.
public struct CacheConformanceHarness: Sendable {
    public let label: String
    public let makePayloadSubject: @Sendable (CacheConformanceConfig) async throws -> ConformanceSubject<ConformancePayload>
    public let makeTextSubject: @Sendable (CacheConformanceConfig) async throws -> ConformanceSubject<String>
    /// The bytes the backing holds under an entry name, or `nil`.
    public let storedBytes: @Sendable (String) async throws -> Data?
    /// Puts bytes under an entry name without going through a cache.
    public let plant: @Sendable (String, Data) async throws -> Void
    /// Makes the entry look `seconds` older (its modification date moves back).
    public let age: @Sendable (String, TimeInterval) async throws -> Void

    public init(
        label: String,
        makePayloadSubject: @escaping @Sendable (CacheConformanceConfig) async throws -> ConformanceSubject<ConformancePayload>,
        makeTextSubject: @escaping @Sendable (CacheConformanceConfig) async throws -> ConformanceSubject<String>,
        storedBytes: @escaping @Sendable (String) async throws -> Data?,
        plant: @escaping @Sendable (String, Data) async throws -> Void,
        age: @escaping @Sendable (String, TimeInterval) async throws -> Void
    ) {
        self.label = label
        self.makePayloadSubject = makePayloadSubject
        self.makeTextSubject = makeTextSubject
        self.storedBytes = storedBytes
        self.plant = plant
        self.age = age
    }
}

// MARK: - CacheRepositoryConformance

/// The behaviour every cache must show, whatever sits under it (BR-RP-11, T-11).
///
/// Each ``Check`` returns the violations it found — an empty array is a pass —
/// so a consumer's test is `#expect(await run(check, on: harness).isEmpty)` and
/// a failure names the backing, the check and the observed behaviour. Nothing
/// here imports a test framework: BackendKit, NetKit and shikki run the SAME
/// suite over their own backings from their own test targets.
public enum CacheRepositoryConformance {

    public enum Check: String, CaseIterable, Sendable, CustomStringConvertible {
        case containerRoundTrip
        case missingEntry
        case deleteRemoves
        case upsertLastWriteWins
        case containerShape
        case rawShape
        case rawStringVerbatim
        case rawStringRejectsNonString
        case namingShapes
        case containerExpiry
        case rawExpiry
        case neverSurvivesAge
        case listIsIsolatedAndSkipsBadEntries
        case unusualIds
        case concurrentSaves
        case largePayload
        case corruptEntry

        public var description: String { rawValue }
    }

    /// Runs one check; the violations it observed (empty means it holds).
    public static func run(_ check: Check, on harness: CacheConformanceHarness) async -> [String] {
        let recorder = Recorder(prefix: "\(harness.label) / \(check.rawValue)")
        let runner = Runner(harness: harness, recorder: recorder)
        do {
            try await runner.run(check)
        } catch {
            await recorder.fail("threw unexpectedly: \(error)")
        }
        return await recorder.violations
    }

    /// The checks that have an implementation — all of them, asserted by the suite's own test.
    public static var implementedChecks: [Check] {
        Check.allCases.filter { Runner.implementations[$0] != nil }
    }

    /// Runs every check; all violations.
    public static func runAll(on harness: CacheConformanceHarness) async -> [String] {
        var all: [String] = []
        for check in Check.allCases {
            all += await run(check, on: harness)
        }
        return all
    }
}

// MARK: - Recorder

private actor Recorder {
    let prefix: String
    private(set) var violations: [String] = []
    private var counter = 0

    init(prefix: String) {
        self.prefix = prefix
    }

    func fail(_ message: String) {
        violations.append("\(prefix): \(message)")
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { fail(message()) }
    }

    /// A cache name no other check shares, so checks never see each other's entries.
    func uniqueName() -> String {
        counter += 1
        return "conf\(counter)-\(UUID().uuidString.prefix(8).lowercased())"
    }
}

// MARK: - Runner

private struct Runner: Sendable {
    let harness: CacheConformanceHarness
    let recorder: Recorder

    /// The envelope probe: which top-level keys an entry's JSON carries.
    private struct EnvelopeProbe: Decodable {
        let body: String?
        let timestamp: Double?
        let modelType: String?
    }

    private static let yearInSeconds: TimeInterval = 365 * 24 * 60 * 60

    /// A naming under test and the entry name it must produce.
    private struct NamingCase {
        let label: String
        let naming: FileNaming
        let entry: @Sendable (_ name: String, _ id: String) -> String
    }

    private func payload(_ n: Int) -> ConformancePayload { ConformancePayload(id: n, name: "item-\(n)") }

    private func config(
        _ name: String,
        ttl: InvalidateTime = .inTime(ttl: 3600),
        envelope: EnvelopeMode = .container,
        naming: FileNaming = .legacy
    ) -> CacheConformanceConfig {
        CacheConformanceConfig(name: name, invalidateTime: ttl, envelope: envelope, naming: naming)
    }

    /// Records a violation unless `body` throws exactly `expected`.
    private func expectThrows(_ expected: CacheRepositoryError, _ what: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            await recorder.fail("\(what): expected \(expected), nothing was thrown")
        } catch {
            await recorder.expect(
                String(describing: error) == String(describing: expected),
                "\(what): expected \(expected), got \(error)")
        }
    }

    /// One implementation per check. A table, not a switch: every `Check` case
    /// must have an entry, and a test asserts it does.
    static let implementations: [CacheRepositoryConformance.Check: @Sendable (Runner) -> () async throws -> Void] = [
        .containerRoundTrip: Runner.containerRoundTrip,
        .missingEntry: Runner.missingEntry,
        .deleteRemoves: Runner.deleteRemoves,
        .upsertLastWriteWins: Runner.upsertLastWriteWins,
        .containerShape: Runner.containerShape,
        .rawShape: Runner.rawShape,
        .rawStringVerbatim: Runner.rawStringVerbatim,
        .rawStringRejectsNonString: Runner.rawStringRejectsNonString,
        .namingShapes: Runner.namingShapes,
        .containerExpiry: Runner.containerExpiry,
        .rawExpiry: Runner.rawExpiry,
        .neverSurvivesAge: Runner.neverSurvivesAge,
        .listIsIsolatedAndSkipsBadEntries: Runner.listIsolation,
        .unusualIds: Runner.unusualIds,
        .concurrentSaves: Runner.concurrentSaves,
        .largePayload: Runner.largePayload,
        .corruptEntry: Runner.corruptEntry,
    ]

    func run(_ check: CacheRepositoryConformance.Check) async throws {
        guard let implementation = Self.implementations[check] else {
            return await recorder.fail("no implementation registered for this check")
        }
        try await implementation(self)()
    }

    // MARK: Checks

    private func containerRoundTrip() async throws {
        let subject = try await harness.makePayloadSubject(config(await recorder.uniqueName()))
        try await subject.save("a", payload(1))
        await recorder.expect(try await subject.exists("a"), "exists is false right after save")
        await recorder.expect(try await subject.get("a") == payload(1), "get does not return what was saved")
        await recorder.expect(try await subject.list() == [payload(1)], "list does not return the saved record")
    }

    private func missingEntry() async throws {
        let subject = try await harness.makePayloadSubject(config(await recorder.uniqueName()))
        await recorder.expect(!(try await subject.exists("nope")), "exists is true for an entry never saved")
        await expectThrows(.notFound, "get of a missing entry") { _ = try await subject.get("nope") }
        await expectThrows(.notFound, "delete of a missing entry") { try await subject.delete("nope") }
    }

    private func deleteRemoves() async throws {
        let name = await recorder.uniqueName()
        let subject = try await harness.makePayloadSubject(config(name))
        try await subject.save("a", payload(1))
        try await subject.delete("a")
        await recorder.expect(!(try await subject.exists("a")), "exists is true after delete")
        await expectThrows(.notFound, "get after delete") { _ = try await subject.get("a") }
        await recorder.expect(
            try await harness.storedBytes("\(name)-a.cache") == nil, "the backing still holds the bytes after delete")
    }

    private func upsertLastWriteWins() async throws {
        let subject = try await harness.makePayloadSubject(config(await recorder.uniqueName()))
        try await subject.save("a", payload(1))
        try await subject.save("a", payload(2))
        await recorder.expect(try await subject.get("a") == payload(2), "the second save did not replace the first")
        await recorder.expect(try await subject.list().count == 1, "an overwrite produced a second record")
    }

    private func containerShape() async throws {
        let name = await recorder.uniqueName()
        let subject = try await harness.makePayloadSubject(config(name, envelope: .container))
        try await subject.save("a", payload(1))
        guard let bytes = try await harness.storedBytes("\(name)-a.cache") else {
            return await recorder.fail("no bytes under the legacy entry name \(name)-a.cache")
        }
        let probe = try JSONDecoder().decode(EnvelopeProbe.self, from: bytes)
        await recorder.expect(
            probe.body != nil && probe.timestamp != nil && probe.modelType != nil,
            ".container bytes must carry body, timestamp and modelType")
    }

    private func rawShape() async throws {
        let name = await recorder.uniqueName()
        let subject = try await harness.makePayloadSubject(config(name, ttl: .never, envelope: .raw))
        try await subject.save("a", payload(7))
        guard let bytes = try await harness.storedBytes("\(name)-a.cache") else {
            return await recorder.fail("no bytes under the legacy entry name \(name)-a.cache")
        }
        await recorder.expect(
            (try? JSONDecoder().decode(ConformancePayload.self, from: bytes)) == payload(7),
            ".raw bytes must BE the model's JSON")
        let probe = try JSONDecoder().decode(EnvelopeProbe.self, from: bytes)
        await recorder.expect(
            probe.body == nil && probe.timestamp == nil && probe.modelType == nil, ".raw bytes must carry no envelope keys")
    }

    private func rawStringVerbatim() async throws {
        let name = await recorder.uniqueName()
        let subject = try await harness.makeTextSubject(config(name, ttl: .never, envelope: .rawString))
        let text = "# Ballot\n\nline one — é\n"
        try await subject.save("ballot", text)
        await recorder.expect(
            try await harness.storedBytes("\(name)-ballot.cache") == Data(text.utf8), ".rawString bytes must be the UTF-8 text verbatim")
        await recorder.expect(try await subject.get("ballot") == text, "get does not return the text saved")
    }

    private func rawStringRejectsNonString() async throws {
        let subject = try await harness.makePayloadSubject(
            config(await recorder.uniqueName(), ttl: .never, envelope: .rawString))
        await expectThrows(.encodedError, "save of a non-String model under .rawString") {
            try await subject.save("a", payload(1))
        }
    }

    private func namingShapes() async throws {
        let cases = [
            NamingCase(label: "legacy", naming: .legacy, entry: { name, id in "\(name)-\(id).cache" }),
            NamingCase(label: "bareId with extension", naming: .bareId(ext: "json"), entry: { _, id in "\(id).json" }),
            NamingCase(label: "bareId verbatim", naming: .bareId(), entry: { _, id in id }),
            NamingCase(
                label: "custom", naming: .custom { name, id in "\(name)_\(id).dat" },
                entry: { name, id in "\(name)_\(id).dat" }),
        ]
        for testCase in cases {
            // A fresh name AND id per case: bareId entries are not namespaced by the cache name.
            let name = await recorder.uniqueName()
            let id = "id-\(UUID().uuidString.prefix(8).lowercased())"
            let subject = try await harness.makePayloadSubject(
                config(name, ttl: .never, envelope: .raw, naming: testCase.naming))
            try await subject.save(id, payload(3))
            let entry = testCase.entry(name, id)
            await recorder.expect(
                try await harness.storedBytes(entry) != nil, "naming '\(testCase.label)' did not write the entry \(entry)")
            await recorder.expect(try await subject.get(id) == payload(3), "naming '\(testCase.label)' does not round-trip")
            try await subject.delete(id)
            await recorder.expect(
                try await harness.storedBytes(entry) == nil, "naming '\(testCase.label)' left the entry \(entry) after delete")
        }
    }

    private func containerExpiry() async throws {
        let subject = try await harness.makePayloadSubject(config(await recorder.uniqueName(), ttl: .inTime(ttl: 0)))
        try await subject.save("a", payload(1))
        await expectThrows(.noCacheAvailable, "get of an entry past its TTL") { _ = try await subject.get("a") }
        await recorder.expect(!(try await subject.exists("a")), "an expired entry was not invalidated")
    }

    private func rawExpiry() async throws {
        let name = await recorder.uniqueName()
        let subject = try await harness.makePayloadSubject(config(name, ttl: .inTime(ttl: 3600), envelope: .raw))
        let entry = "\(name)-a.cache"
        try await subject.save("a", payload(1))
        try await harness.age(entry, 600)
        await recorder.expect(try await subject.get("a") == payload(1), "an entry younger than its TTL was not served")
        try await harness.age(entry, 7200)
        await expectThrows(.noCacheAvailable, "get of a .raw entry older than its TTL") { _ = try await subject.get("a") }
        await recorder.expect(!(try await subject.exists("a")), "an expired .raw entry was not invalidated")
    }

    private func neverSurvivesAge() async throws {
        let name = await recorder.uniqueName()
        let raw = try await harness.makePayloadSubject(config(name, ttl: .never, envelope: .raw))
        try await raw.save("a", payload(4))
        try await harness.age("\(name)-a.cache", Self.yearInSeconds)
        await recorder.expect(try await raw.get("a") == payload(4), ".raw with .never must survive any age")

        let container = try await harness.makePayloadSubject(config(await recorder.uniqueName(), ttl: .never))
        try await container.save("a", payload(5))
        await recorder.expect(try await container.get("a") == payload(5), ".container with .never must survive")
    }

    private func listIsolation() async throws {
        let nameA = await recorder.uniqueName()
        let nameB = await recorder.uniqueName()
        let a = try await harness.makePayloadSubject(config(nameA))
        let b = try await harness.makePayloadSubject(config(nameB))
        try await a.save("1", payload(1))
        try await a.save("2", payload(2))
        try await b.save("1", payload(9))
        // Entries that are not this cache's records, planted behind its back.
        try await harness.plant("\(nameA)-garbage.cache", Data("not json".utf8))
        try await harness.plant("unrelated-\(nameA).txt", Data("x".utf8))
        let listedA = try await a.list().sorted { $0.id < $1.id }
        await recorder.expect(listedA == [payload(1), payload(2)], "list of A returned \(listedA)")
        await recorder.expect(try await b.list() == [payload(9)], "list of B saw A's entries")

        let expired = try await harness.makePayloadSubject(config(await recorder.uniqueName(), ttl: .inTime(ttl: 0)))
        try await expired.save("x", payload(1))
        await recorder.expect(try await expired.list().isEmpty, "list returned an expired record")
        await recorder.expect(try await expired.exists("x"), "list invalidated an entry; only get may")
    }

    private func unusualIds() async throws {
        let subject = try await harness.makePayloadSubject(config(await recorder.uniqueName()))
        let ids = ["id with space", "é-ü-ß", "UPPER.lower", "dots.in.name", "a-b_c"]
        for (index, id) in ids.enumerated() {
            try await subject.save(id, payload(index))
        }
        for (index, id) in ids.enumerated() {
            await recorder.expect(try await subject.get(id) == payload(index), "id '\(id)' does not round-trip")
        }
    }

    private func concurrentSaves() async throws {
        let subject = try await harness.makePayloadSubject(config(await recorder.uniqueName()))
        let count = 20
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask { try await subject.save("c\(index)", ConformancePayload(id: index, name: "item-\(index)")) }
            }
            try await group.waitForAll()
        }
        for index in 0..<count {
            await recorder.expect(try await subject.get("c\(index)") == payload(index), "concurrent save c\(index) was lost or corrupted")
        }
        await recorder.expect(try await subject.list().count == count, "list after \(count) concurrent saves")
    }

    private func largePayload() async throws {
        let subject = try await harness.makePayloadSubject(config(await recorder.uniqueName()))
        let big = ConformancePayload(id: 1, name: String(repeating: "x", count: 300_000))
        try await subject.save("big", big)
        await recorder.expect(try await subject.get("big") == big, "a 300 KB record does not round-trip")
    }

    private func corruptEntry() async throws {
        for envelope in [EnvelopeMode.container, .raw] {
            let name = await recorder.uniqueName()
            let subject = try await harness.makePayloadSubject(config(name, ttl: .never, envelope: envelope))
            try await harness.plant("\(name)-bad.cache", Data("{ not the model".utf8))
            await expectThrows(.decodedError, "get of a corrupt \(envelope) entry") { _ = try await subject.get("bad") }
        }
    }
}
