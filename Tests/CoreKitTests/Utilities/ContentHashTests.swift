import Foundation
@testable import CoreKit
import Testing

// MARK: - ContentHashTests
//
// Vectors pin the wire contract: lowercase hex SHA-256 — the exact sidecar
// format kagami already emits, so fleet adoption never invalidates caches.

@Suite("ContentHash")
struct ContentHashTests {

    // NIST/RFC-known SHA-256 vectors.
    @Test("empty input matches the canonical SHA-256 empty digest")
    func emptyVector() {
        #expect(
            ContentHash.sha256(Data())
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    @Test("'abc' matches the canonical SHA-256 vector")
    func abcVector() {
        #expect(
            ContentHash.sha256("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("string and data overloads agree")
    func overloadsAgree() {
        let s = "shikki content addressing"
        #expect(ContentHash.sha256(s) == ContentHash.sha256(Data(s.utf8)))
    }

    @Test("output is always 64 lowercase hex characters")
    func formatContract() {
        let h = ContentHash.sha256("anything")
        #expect(h.count == 64)
        #expect(h == h.lowercased())
        #expect(h.allSatisfy { $0.isHexDigit })
    }

    @Test("streaming file hash equals in-memory hash across chunk boundaries")
    func streamingParity() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("content-hash-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("blob.bin")
        // 3 MiB + 17 bytes: exercises multiple chunks + a ragged tail.
        var data = Data(count: 3 << 20)
        for i in 0..<data.count where i % 4096 == 0 { data[i] = UInt8(truncatingIfNeeded: i) }
        data.append(contentsOf: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17])
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let streamed = try ContentHash.sha256(contentsOf: url)
        #expect(streamed == ContentHash.sha256(data))
        // Tiny chunk size forces many update() calls — same digest.
        let tinyChunks = try ContentHash.sha256(contentsOf: url, chunkSize: 1024)
        #expect(tinyChunks == streamed)
    }

    @Test("missing file throws rather than returning a digest")
    func missingFileThrows() {
        #expect(throws: (any Error).self) {
            _ = try ContentHash.sha256(
                contentsOf: URL(fileURLWithPath: "/nonexistent/content-hash-test")
            )
        }
    }

    @Test("Incremental fold over split input equals one-shot digest")
    func incrementalEqualsOneShot() {
        let payload = "shikki incremental fold"
        var hasher = ContentHash.Incremental()
        // Split at an arbitrary boundary — fold must be chunking-invariant.
        hasher.update(Data(payload.prefix(7).utf8))
        hasher.update(String(payload.dropFirst(7)))
        #expect(hasher.finalizeHex() == ContentHash.sha256(payload))
    }

    @Test("Incremental with a single empty update matches the empty digest")
    func incrementalEmpty() {
        var hasher = ContentHash.Incremental()
        hasher.update(Data())
        #expect(
            hasher.finalizeHex()
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }
}
