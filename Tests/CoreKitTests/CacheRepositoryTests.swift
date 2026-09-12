import XCTest
@testable import CoreKit

struct TestModel: Codable, Equatable, Sendable {
    let id: Int
    let name: String
}

final class CacheRepositoryTests: XCTestCase {
    var cache: CacheRepository<TestModel>!
    let testId = "test-item-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        // Back-compat call: existing 2-arg signature must still compile & work.
        cache = CacheRepository<TestModel>("CacheRepoTests", invalidateTime: .inTime(ttl: 3600))
    }

    override func tearDown() {
        // Clean up any cached files
        try? cache.delete(testId)
        cache = nil
        super.tearDown()
    }

    // MARK: - Save & Get

    func testSaveAndGet() throws {
        let model = TestModel(id: 1, name: "Test")

        try cache.save(testId, data: model)
        XCTAssertTrue(cache.exists(testId))

        let retrieved: TestModel = try cache.get(testId)
        XCTAssertEqual(retrieved, model)
    }

    // MARK: - Exists

    func testExistsReturnsFalseWhenNotCached() {
        XCTAssertFalse(cache.exists("nonexistent-\(UUID().uuidString)"))
    }

    func testExistsReturnsTrueWhenCached() throws {
        let model = TestModel(id: 2, name: "Exists Test")
        try cache.save(testId, data: model)
        XCTAssertTrue(cache.exists(testId))
    }

    // MARK: - Delete

    func testDelete() throws {
        let model = TestModel(id: 3, name: "Delete Test")
        try cache.save(testId, data: model)
        XCTAssertTrue(cache.exists(testId))

        try cache.delete(testId)
        XCTAssertFalse(cache.exists(testId))
    }

    func testDeleteNonexistentThrows() {
        XCTAssertThrowsError(try cache.delete("nonexistent-\(UUID().uuidString)")) { error in
            guard let cacheError = error as? CacheRepositoryError else {
                XCTFail("Expected CacheRepositoryError, got \(error)")
                return
            }
            XCTAssertEqual(String(describing: cacheError), String(describing: CacheRepositoryError.notFound))
        }
    }

    // MARK: - Get Non-existent

    func testGetNonexistentThrows() {
        XCTAssertThrowsError(try cache.get("nonexistent-\(UUID().uuidString)")) { error in
            guard let cacheError = error as? CacheRepositoryError else {
                XCTFail("Expected CacheRepositoryError, got \(error)")
                return
            }
            XCTAssertEqual(String(describing: cacheError), String(describing: CacheRepositoryError.notFound))
        }
    }

    // MARK: - TTL Expiry

    func testExpiredCacheIsInvalidated() throws {
        // Create a cache with 0 TTL (immediately expired)
        let expiredCache = CacheRepository<TestModel>("CacheRepoExpiredTests", invalidateTime: .inTime(ttl: 0))
        let expiredId = "expired-\(UUID().uuidString)"
        let model = TestModel(id: 4, name: "Expired")

        try expiredCache.save(expiredId, data: model)
        XCTAssertTrue(expiredCache.exists(expiredId))

        // Should throw because cache is expired (and hasNetwork defaults to true in sync version)
        XCTAssertThrowsError(try expiredCache.get(expiredId))
    }

    // MARK: - Never Invalidate

    func testNeverInvalidateAlwaysReturns() throws {
        let neverCache = CacheRepository<TestModel>("CacheRepoNeverTests", invalidateTime: .never)
        let neverId = "never-\(UUID().uuidString)"
        let model = TestModel(id: 5, name: "Never Expire")

        try neverCache.save(neverId, data: model)
        let retrieved: TestModel = try neverCache.get(neverId)
        XCTAssertEqual(retrieved, model)

        // Cleanup
        try? neverCache.delete(neverId)
    }

    // MARK: - Back-compat surface

    /// The 2-arg `init(_:invalidateTime:)` shape used all over the ecosystem
    /// must still compile & default to `.container` envelope + `documentDirectory`.
    func testBackCompatTwoArgInitDefaultsToContainerEnvelope() {
        let legacy = CacheRepository<TestModel>("BackCompatDefaults", invalidateTime: .inTime(ttl: 3600))
        XCTAssertEqual(legacy.envelope, .container)
    }

    /// The pre-existing 1-arg default-TTL init must also still compile.
    func testBackCompatOneArgInitStillCompiles() {
        let legacy = CacheRepository<TestModel>("BackCompatOneArg")
        XCTAssertEqual(legacy.envelope, .container)
    }

    // MARK: - Directory override

    private func makeTempDir(_ label: String = "cache") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheRepoTests-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    func testDirectoryOverrideCreatesDirectoryAndWritesThere() throws {
        let dir = makeTempDir("dir-override")
        // Directory does NOT exist yet — init must create it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        let repo = CacheRepository<TestModel>(
            "DirOverride",
            invalidateTime: .inTime(ttl: 3600),
            baseDirectory: dir
        )
        let id = "dir-\(UUID().uuidString)"
        let model = TestModel(id: 7, name: "in-tempdir")

        try repo.save(id, data: model)

        // The file must exist under the overridden directory, NOT under .documentDirectory.
        let expectedFile = dir.appendingPathComponent("DirOverride-\(id).cache")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expectedFile.path),
            "expected cache file at \(expectedFile.path) — got nothing there"
        )

        let round: TestModel = try repo.get(id)
        XCTAssertEqual(round, model)

        // Cleanup
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Raw envelope — round-trip + on-disk shape

    func testRawEnvelopeRoundTrip() throws {
        let dir = makeTempDir("raw-roundtrip")
        let repo = CacheRepository<TestModel>(
            "RawRT",
            invalidateTime: .never,
            baseDirectory: dir,
            envelope: .raw
        )
        let id = "raw-\(UUID().uuidString)"
        let model = TestModel(id: 42, name: "raw-round-trip")

        try repo.save(id, data: model)
        XCTAssertTrue(repo.exists(id))

        let round: TestModel = try repo.get(id)
        XCTAssertEqual(round, model)

        try repo.delete(id)
        XCTAssertFalse(repo.exists(id))

        try? FileManager.default.removeItem(at: dir)
    }

    /// The whole point of `.raw`: the file bytes MUST be a direct JSON dump of
    /// `ModelType`, cat/jq-able, with no `body`/`timestamp`/`modelType` wrapper.
    func testRawEnvelopeFileIsDirectModelJSON() throws {
        let dir = makeTempDir("raw-shape")
        let repo = CacheRepository<TestModel>(
            "RawShape",
            invalidateTime: .never,
            baseDirectory: dir,
            envelope: .raw
        )
        let id = "shape-\(UUID().uuidString)"
        let model = TestModel(id: 99, name: "shape-check")
        try repo.save(id, data: model)

        let fileURL = dir.appendingPathComponent("RawShape-\(id).cache")
        let raw = try Data(contentsOf: fileURL)
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertNotNil(json, "raw cache file must parse as a JSON object")

        // The direct-shape assertions.
        XCTAssertEqual(json?["id"] as? Int, 99)
        XCTAssertEqual(json?["name"] as? String, "shape-check")

        // Envelope keys MUST NOT be present.
        XCTAssertNil(json?["body"], ".raw file must NOT contain envelope 'body' key")
        XCTAssertNil(json?["timestamp"], ".raw file must NOT contain envelope 'timestamp' key")
        XCTAssertNil(json?["modelType"], ".raw file must NOT contain envelope 'modelType' key")
        XCTAssertNil(json?["invalideTime"], ".raw file must NOT contain envelope 'invalideTime' key")
        XCTAssertNil(json?["readCount"], ".raw file must NOT contain envelope 'readCount' key")

        try? FileManager.default.removeItem(at: dir)
    }

    /// Container envelope keeps its historical shape — regression guard so that
    /// `.container` is genuinely the back-compat default.
    func testContainerEnvelopeFileStillWrapsInEnvelope() throws {
        let dir = makeTempDir("container-shape")
        let repo = CacheRepository<TestModel>(
            "ContainerShape",
            invalidateTime: .inTime(ttl: 3600),
            baseDirectory: dir,
            envelope: .container
        )
        let id = "container-\(UUID().uuidString)"
        try repo.save(id, data: TestModel(id: 1, name: "in-envelope"))

        let fileURL = dir.appendingPathComponent("ContainerShape-\(id).cache")
        let raw = try Data(contentsOf: fileURL)
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertNotNil(json?["body"], ".container file MUST contain 'body' envelope key")
        XCTAssertNotNil(json?["timestamp"], ".container file MUST contain 'timestamp' envelope key")
        XCTAssertNotNil(json?["modelType"], ".container file MUST contain 'modelType' envelope key")

        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - .raw + .never: survives any age

    /// `.raw` + `.never` MUST return the value regardless of file age.
    /// Simulates an ancient file by back-dating its mtime by ~1 year.
    func testRawNeverSurvivesAncientFile() throws {
        let dir = makeTempDir("raw-never")
        let repo = CacheRepository<TestModel>(
            "RawNever",
            invalidateTime: .never,
            baseDirectory: dir,
            envelope: .raw
        )
        let id = "ancient-\(UUID().uuidString)"
        let model = TestModel(id: 8, name: "ancient")
        try repo.save(id, data: model)

        // Back-date the file's mtime by 1 year.
        let fileURL = dir.appendingPathComponent("RawNever-\(id).cache")
        let ancient = Date(timeIntervalSinceNow: -365 * 24 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: ancient],
            ofItemAtPath: fileURL.path
        )

        // Ancient file with .never must still round-trip.
        let round: TestModel = try repo.get(id)
        XCTAssertEqual(round, model)

        try? FileManager.default.removeItem(at: dir)
    }

    /// Sibling proof: `.raw` + `.inTime(ttl: 0)` DOES invalidate expired files —
    /// this is what tells us the `.never` guarantee above isn't accidental.
    func testRawInTimeExpiredFileIsInvalidated() throws {
        let dir = makeTempDir("raw-expired")
        let repo = CacheRepository<TestModel>(
            "RawExpired",
            invalidateTime: .inTime(ttl: 0),
            baseDirectory: dir,
            envelope: .raw
        )
        let id = "expired-\(UUID().uuidString)"
        try repo.save(id, data: TestModel(id: 9, name: "expired"))

        // ttl=0 → any mtime in the past is "expired" — sync get() has hasNetwork=true so it invalidates.
        XCTAssertThrowsError(try repo.get(id))

        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Container + .never (regression: pre-existing behavior)

    func testContainerNeverSurvivesAncientFile() throws {
        let dir = makeTempDir("container-never")
        let repo = CacheRepository<TestModel>(
            "ContainerNever",
            invalidateTime: .never,
            baseDirectory: dir,
            envelope: .container
        )
        let id = "cn-\(UUID().uuidString)"
        let model = TestModel(id: 10, name: "container-never")
        try repo.save(id, data: model)

        // Simulate an ancient file — .never uses the envelope timestamp, but
        // the guarantee still holds: .never returns regardless.
        let round: TestModel = try repo.get(id)
        XCTAssertEqual(round, model)

        try? FileManager.default.removeItem(at: dir)
    }

    func testCustomBaseDirectoryWritesThereNotDocuments() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("corekit-basedir-\(UUID().uuidString)", isDirectory: true)
        let scoped = CacheRepository<TestModel>(
            "WsMeta", invalidateTime: .never, baseDirectory: tmp
        )
        let model = TestModel(id: 42, name: "scoped")

        try scoped.save("x", data: model)

        // File landed under the custom base dir, not ~/Documents.
        let expected = tmp.appendingPathComponent("WsMeta-x.cache")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                      "cache file must be written under the custom baseDirectory")
        XCTAssertEqual(try scoped.get("x"), model)

        try? FileManager.default.removeItem(at: tmp)
    }

    func testCustomBaseDirectoryIsCreatedIfMissing() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("corekit-mkdir-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
        let scoped = CacheRepository<TestModel>("N", baseDirectory: tmp)

        try scoped.save("y", data: TestModel(id: 1, name: "a"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path),
                      "save must create intermediate base directories")
        try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
    }
}
