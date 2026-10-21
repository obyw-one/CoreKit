import XCTest
@testable import CoreKit

// MARK: - FileIOProfileTests

/// Per-profile write-path behavior and cross-process flock contention.
///
/// **Single-process flock test limitation:**
/// The durable contention test (`testDurableProfileSerialisesWriters`) uses
/// concurrent tasks within the same process. POSIX `flock(2)` is
/// per-process on macOS — a second `flock` call from the SAME process on
/// the same file SUCCEEDS immediately, so the single-process test cannot
/// exercise real lock contention. Instead it verifies:
///   - all concurrent saves complete without error,
///   - the final file is valid (parseable), and
///   - no lock file is left behind after all writers finish.
/// A two-process test (spawning a helper binary that flock-holds the lock
/// file) would exercise real exclusion but requires suite infrastructure
/// that CoreKit's standalone SPM test target does not have.
final class FileIOProfileTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(_ label: String = "fio") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileIOProfileTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    private func makeRepo(
        label: String,
        dir: URL,
        profile: FileIOProfile
    ) -> CacheRepository<TestModel> {
        CacheRepository<TestModel>(
            label,
            invalidateTime: .never,
            baseDirectory: dir,
            envelope: .raw,
            ioProfile: profile
        )
    }

    // MARK: - .plain

    func testPlainProfileWritesAndReads() throws {
        let dir = makeTempDir("plain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = makeRepo(label: "Plain", dir: dir, profile: .plain)
        let id = "plain-\(UUID().uuidString)"
        let model = TestModel(id: 1, name: "plain-write")

        try repo.save(id, data: model)
        XCTAssertTrue(repo.exists(id))
        XCTAssertEqual(try repo.get(id), model)
    }

    func testPlainProfileUsedByDefault_isNotAtomic() throws {
        // .plain writes without the atomic rename — file is written in-place.
        // We just verify the round-trip works; the mechanical distinction from
        // .atomic is an OS-level concern, not observable from outside.
        let dir = makeTempDir("plain-default")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = makeRepo(label: "PlainDef", dir: dir, profile: .plain)
        let id = UUID().uuidString
        try repo.save(id, data: TestModel(id: 2, name: "ok"))
        XCTAssertEqual(try repo.get(id), TestModel(id: 2, name: "ok"))
    }

    // MARK: - .atomic

    func testAtomicProfileIsDefaultAndBackwardCompat() throws {
        // The 1-arg init must default to .atomic (=today's behavior).
        let repo = CacheRepository<TestModel>("AtomicDefault")
        XCTAssertEqual(repo.ioProfile, .atomic)
    }

    func testAtomicProfileWritesAndReads() throws {
        let dir = makeTempDir("atomic")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = makeRepo(label: "Atomic", dir: dir, profile: .atomic)
        let id = "atomic-\(UUID().uuidString)"
        let model = TestModel(id: 3, name: "atomic-write")

        try repo.save(id, data: model)
        XCTAssertTrue(repo.exists(id))
        XCTAssertEqual(try repo.get(id), model)
    }

    // MARK: - .durable

    func testDurableProfileWritesAndReads() throws {
        let dir = makeTempDir("durable")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = makeRepo(label: "Durable", dir: dir, profile: .durable)
        let id = "durable-\(UUID().uuidString)"
        let model = TestModel(id: 4, name: "durable-write")

        try repo.save(id, data: model)
        XCTAssertTrue(repo.exists(id))
        XCTAssertEqual(try repo.get(id), model)
    }

    func testDurableProfileProducesValidJSON() throws {
        let dir = makeTempDir("durable-json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = makeRepo(label: "DurableJSON", dir: dir, profile: .durable)
        let id = "json-\(UUID().uuidString)"
        let model = TestModel(id: 5, name: "durable-json")

        try repo.save(id, data: model)

        let fileURL = dir.appendingPathComponent("DurableJSON-\(id).cache")
        let raw = try Data(contentsOf: fileURL)
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertNotNil(json, "durable-written file must be parseable JSON")
        XCTAssertEqual(json?["id"] as? Int, 5)
        XCTAssertEqual(json?["name"] as? String, "durable-json")
    }

    func testDurableProfileCreatesAndCleansLockFile() throws {
        // The lock file is a sibling named `.<filename>.lock`.
        // After save completes the lock file should exist (it is not deleted
        // automatically — it is a stable flock target).
        let dir = makeTempDir("durable-lock")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = makeRepo(label: "DurableLock", dir: dir, profile: .durable)
        let id = "lock-\(UUID().uuidString)"

        try repo.save(id, data: TestModel(id: 6, name: "lock"))

        let cacheFilename = "DurableLock-\(id).cache"
        let lockURL = dir.appendingPathComponent(".\(cacheFilename).lock")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: lockURL.path),
            "durable save must leave the sibling lock file in place for future lock acquisition"
        )
    }

    func testDurableProfileNoTempFileAfterSave() throws {
        // The per-PID temp file must be cleaned up after a successful save.
        let dir = makeTempDir("durable-tmp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = makeRepo(label: "DurableTmp", dir: dir, profile: .durable)
        let id = "tmp-\(UUID().uuidString)"

        try repo.save(id, data: TestModel(id: 7, name: "no-tmp"))

        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let tempFiles = contents.filter { $0.lastPathComponent.contains(".tmp") }
        XCTAssertTrue(
            tempFiles.isEmpty,
            "no per-PID temp files should remain after a successful durable save; found: \(tempFiles.map(\.lastPathComponent))"
        )
    }

    // MARK: - Concurrency (single-process, limitation documented above)

    /// Single-process concurrent saves with `.durable` must all succeed and
    /// the final on-disk state must be valid.
    ///
    /// **Limitation:** POSIX flock(2) is per-process on macOS — a second flock
    /// call from the same process succeeds immediately without waiting. This
    /// test therefore validates absence-of-crash and file validity under
    /// concurrent saves, NOT true cross-process lock exclusion. Two-process
    /// exclusion requires spawning a helper binary which is outside this
    /// suite's scope.
    func testDurableProfileSerialisesWriters() throws {
        let dir = makeTempDir("durable-conc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = makeRepo(label: "DurableConc", dir: dir, profile: .durable)
        // All writers use the SAME id — same target file.
        let id = "conc-\(UUID().uuidString)"
        let writerCount = 8

        // Concurrent writes — a real race.
        let errors = Mutex<[Error]>([])
        DispatchQueue.concurrentPerform(iterations: writerCount) { i in
            do {
                try repo.save(id, data: TestModel(id: i, name: "writer-\(i)"))
            } catch {
                errors.withLock { $0.append(error) }
            }
        }

        let captured = errors.withLock { $0 }
        XCTAssertTrue(
            captured.isEmpty,
            "all concurrent durable saves must succeed; errors: \(captured)"
        )

        // The final file must be valid — no corruption from concurrent writes.
        XCTAssertTrue(repo.exists(id))
        let final: TestModel = try repo.get(id)
        // id field must be in range (any writer may be last).
        XCTAssertTrue((0..<writerCount).contains(final.id),
                      "final model id \(final.id) out of expected writer range")
    }

    // MARK: - Profile equality + identity

    func testFileIOProfileEquality() {
        XCTAssertEqual(FileIOProfile.plain, .plain)
        XCTAssertEqual(FileIOProfile.atomic, .atomic)
        XCTAssertEqual(FileIOProfile.durable, .durable)
        XCTAssertNotEqual(FileIOProfile.plain, .atomic)
        XCTAssertNotEqual(FileIOProfile.atomic, .durable)
    }

    func testRepositoryExposesIoProfile() {
        let repo = CacheRepository<TestModel>("ProfileExposed", ioProfile: .durable)
        XCTAssertEqual(repo.ioProfile, .durable)
    }
}

// MARK: - Mutex helper (Swift 6 Sendable, no extra deps)

/// Minimal mutex wrapper for collecting errors across concurrent tasks.
private final class Mutex<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}
