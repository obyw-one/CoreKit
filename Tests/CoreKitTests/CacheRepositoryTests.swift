@testable import CoreKit
import XCTest

struct TestModel: Codable, Equatable, Sendable {
    let id: Int
    let name: String
}

final class CacheRepositoryTests: XCTestCase {

    var cache: CacheRepository<TestModel>!
    let testId = "test-item-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
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

    // MARK: - Base Directory (CLI / per-project cache)

    func testCustomBaseDirectoryWritesThereNotDocuments() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("corekit-basedir-\(UUID().uuidString)", isDirectory: true)
        let scoped = CacheRepository<TestModel>(
            "WsMeta", invalidateTime: .never, baseDirectory: tmp)
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
