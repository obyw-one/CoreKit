import XCTest
@testable import CoreKit

/// 0.3.1 — filename strategy + codec injection + `.rawString` passthrough.
///
/// The three hooks that let contractual file stores collapse onto
/// CacheRepository without breaking their on-disk contracts:
/// shikki's `.shikki-unit.json` worktree manifests (exact filename +
/// iso8601/pretty JSON), `pr-<n>.dossier.json` caches (legacy corpus
/// compatibility), and `pr-<n>-<sha>.md` ballots (markdown, not JSON).
final class CacheNamingCodecTests: XCTestCase {
    struct DatedModel: Codable, Equatable, Sendable {
        let name: String
        let stamp: Date
    }

    var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-naming-codec-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        super.tearDown()
    }

    // MARK: - FileNaming

    func testLegacyNamingUnchanged() throws {
        let cache = CacheRepository<TestModel>(
            "unit", invalidateTime: .never, baseDirectory: dir, envelope: .raw
        )
        try cache.save("a", data: TestModel(id: 1, name: "x"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("unit-a.cache").path),
            "default naming must stay the historical <name>-<id>.cache"
        )
    }

    func testBareIdWithExtension() throws {
        let cache = CacheRepository<TestModel>(
            "ignored", invalidateTime: .never, baseDirectory: dir,
            envelope: .raw, naming: .bareId(ext: "json")
        )
        try cache.save("pr-7.dossier", data: TestModel(id: 7, name: "d"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("pr-7.dossier.json").path)
        )
        XCTAssertEqual(try cache.get("pr-7.dossier"), TestModel(id: 7, name: "d"))
    }

    func testBareIdVerbatim_dotfileContract() throws {
        // The shikki BR-11 case: the id IS the whole contractual filename.
        let cache = CacheRepository<TestModel>(
            "ignored", invalidateTime: .never, baseDirectory: dir,
            envelope: .raw, naming: .bareId()
        )
        try cache.save(".shikki-unit.json", data: TestModel(id: 1, name: "w1"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(".shikki-unit.json").path)
        )
        XCTAssertEqual(try cache.get(".shikki-unit.json"), TestModel(id: 1, name: "w1"))
    }

    func testCustomNaming() throws {
        let cache = CacheRepository<TestModel>(
            "ballots", invalidateTime: .never, baseDirectory: dir,
            envelope: .raw, naming: .custom { name, id in "\(name)~\(id).v2" }
        )
        try cache.save("42", data: TestModel(id: 42, name: "c"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("ballots~42.v2").path)
        )
        XCTAssertEqual(try cache.get("42"), TestModel(id: 42, name: "c"))
    }

    // MARK: - CacheCodec (.raw only)

    func testHumanReadableCodec_iso8601RoundTripAndShape() throws {
        let cache = CacheRepository<DatedModel>(
            "manifest", invalidateTime: .never, baseDirectory: dir,
            envelope: .raw, naming: .bareId(ext: "json"), codec: .humanReadable
        )
        let stamp = Date(timeIntervalSince1970: 1_753_000_000)
        try cache.save("m", data: DatedModel(name: "prov", stamp: stamp))

        let decoded = try cache.get("m")
        XCTAssertEqual(decoded.name, "prov")
        XCTAssertEqual(
            decoded.stamp.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 1.0
        )

        // The file bytes carry the human contract: iso8601 date string,
        // pretty-printed (newlines), sorted keys ("name" before "stamp").
        let bytes = try String(
            contentsOf: dir.appendingPathComponent("m.json"), encoding: .utf8
        )
        XCTAssertTrue(bytes.contains("T"), "date must be an iso8601 string, not a numeric interval")
        XCTAssertTrue(bytes.contains("\n"), "pretty-printed output expected")
        XCTAssertLessThan(
            try XCTUnwrap(bytes.range(of: "\"name\"")?.lowerBound), try XCTUnwrap(bytes.range(of: "\"stamp\"")?.lowerBound),
            "sortedKeys expected"
        )
    }

    func testDefaultCodecKeepsHistoricalRawBytes() throws {
        // Guard: default codec must stay the bare encoder — existing .raw
        // corpora (numeric dates, compact) keep decoding.
        let cache = CacheRepository<DatedModel>(
            "raw", invalidateTime: .never, baseDirectory: dir, envelope: .raw
        )
        try cache.save("d", data: DatedModel(name: "n", stamp: Date()))
        let bytes = try String(
            contentsOf: dir.appendingPathComponent("raw-d.cache"), encoding: .utf8
        )
        XCTAssertFalse(bytes.contains("\n"), "default .raw output must stay compact")
    }

    // MARK: - .rawString envelope

    func testRawStringVerbatimMarkdown() throws {
        let cache = CacheRepository<String>(
            "ballot", invalidateTime: .never, baseDirectory: dir,
            envelope: .rawString, naming: .bareId(ext: "md")
        )
        let markdown = "# Ballot\n\n- [ ] item one\n- [x] item two\n"
        try cache.save("pr-9-abc123", data: markdown)

        // The file IS the markdown — no JSON quoting/escaping.
        let bytes = try String(
            contentsOf: dir.appendingPathComponent("pr-9-abc123.md"), encoding: .utf8
        )
        XCTAssertEqual(bytes, markdown)
        XCTAssertEqual(try cache.get("pr-9-abc123"), markdown)
    }

    func testRawStringRejectsNonStringModel() throws {
        let cache = CacheRepository<TestModel>(
            "bad", invalidateTime: .never, baseDirectory: dir, envelope: .rawString
        )
        XCTAssertThrowsError(try cache.save("x", data: TestModel(id: 1, name: "no"))) { error in
            XCTAssertEqual(error as? CacheRepositoryError, .encodedError)
        }
    }
}
