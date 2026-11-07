import CoreKit
import CoreKitTestSupport
import Foundation
import Testing

// MARK: - LocalFolderCacheBackingTests

@Suite("LocalFolderCacheBacking — one directory of files, contained (BR-RP-04)")
struct LocalFolderCacheBackingTests {

    private static let separator = PathVocabulary.wireSeparator
    private let scratch = TestScratch.forPackage()

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = try scratch.makeScratchDir(scope: "local-folder-backing")
        defer { try? scratch.removeScratchDir(directory) }
        try await body(directory)
    }

    @Test("it creates its directory, nested if need be, and a write lands there")
    func createsDirectory() async throws {
        try await withDirectory { root in
            let nested = root.appendingPathComponent("a", isDirectory: true).appendingPathComponent("b", isDirectory: true)
            let backing = LocalFolderCacheBacking(directory: nested)
            #expect(FileManager.default.fileExists(atPath: nested.path))
            try backing.write(Data("x".utf8), as: "entry")
            #expect(FileManager.default.fileExists(atPath: nested.appendingPathComponent("entry").path))
        }
    }

    @Test("an entry that climbs out of the directory is refused for every verb")
    func climbingEntryRefused() async throws {
        try await withDirectory { root in
            let backing = LocalFolderCacheBacking(directory: root.appendingPathComponent("inside", isDirectory: true))
            let climbing = [PathVocabulary.parentComponent, "outside.json"].joined(separator: Self.separator)
            #expect(throws: CacheBackingError.entryEscapesLocation(entry: climbing)) {
                try backing.write(Data("x".utf8), as: climbing)
            }
            #expect(throws: CacheBackingError.entryEscapesLocation(entry: climbing)) { _ = try backing.read(climbing) }
            #expect(throws: CacheBackingError.entryEscapesLocation(entry: climbing)) { _ = try backing.remove(climbing) }
            #expect(throws: CacheBackingError.entryEscapesLocation(entry: climbing)) { _ = try backing.contains(climbing) }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.json").path),
                    "the refused write still created a file outside")
        }
    }

    @Test("a symlink inside the directory that leaves it is refused")
    func symlinkEscapeRefused() async throws {
        try await withDirectory { root in
            let inside = root.appendingPathComponent("inside", isDirectory: true)
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            let backing = LocalFolderCacheBacking(directory: inside)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: inside.appendingPathComponent("link"), withDestinationURL: outside)
            let through = ["link", "stolen.json"].joined(separator: Self.separator)
            #expect(throws: CacheBackingError.entryEscapesLocation(entry: through)) {
                try backing.write(Data("x".utf8), as: through)
            }
        }
    }

    @Test("a nested entry name inside the directory is legal when its folder exists")
    func nestedEntryAllowed() async throws {
        try await withDirectory { root in
            let backing = LocalFolderCacheBacking(directory: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
            let nested = ["sub", "entry.json"].joined(separator: Self.separator)
            try backing.write(Data("n".utf8), as: nested)
            #expect(try backing.read(nested)?.data == Data("n".utf8))
        }
    }

    @Test("names() leaves out hidden files: the durable profile's lock and temp files are not entries")
    func hiddenFilesAreNotEntries() async throws {
        try await withDirectory { root in
            let backing = LocalFolderCacheBacking(directory: root, ioProfile: .durable)
            try backing.write(Data("x".utf8), as: "kept.json")
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".kept.json.lock").path),
                    "the durable profile should have left its lock file")
            #expect(try backing.names() == ["kept.json"])
        }
    }

    @Test("names() of a directory that was removed is empty, not an error")
    func missingDirectoryHasNoEntries() async throws {
        try await withDirectory { root in
            let directory = root.appendingPathComponent("gone", isDirectory: true)
            let backing = LocalFolderCacheBacking(directory: directory)
            try FileManager.default.removeItem(at: directory)
            #expect(try backing.names().isEmpty)
            #expect(try backing.read("anything") == nil)
        }
    }

    @Test("the write profile is reported, and it is what the repository exposes")
    func profileReported() async throws {
        try await withDirectory { root in
            for profile in [FileIOProfile.plain, .atomic, .durable] {
                let backing = LocalFolderCacheBacking(directory: root, ioProfile: profile)
                #expect(backing.fileIOProfile == profile)
                let repository = CacheRepository<ConformancePayload>("p", backing: backing)
                #expect(repository.ioProfile == profile)
            }
        }
    }

    @Test("the legacy initialiser builds exactly this backing: same file, same name, same profile")
    func legacyInitialiserIsThisBacking() async throws {
        try await withDirectory { root in
            let legacy = CacheRepository<ConformancePayload>("Legacy", baseDirectory: root, ioProfile: .durable)
            let injected = CacheRepository<ConformancePayload>(
                "Legacy", backing: LocalFolderCacheBacking(directory: root, ioProfile: .durable))
            try legacy.save("a", data: ConformancePayload(id: 1, name: "x"))
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Legacy-a.cache").path))
            #expect(try injected.get("a") == ConformancePayload(id: 1, name: "x"), "the injected twin cannot read the legacy file")
            #expect(legacy.ioProfile == .durable && injected.ioProfile == .durable)
        }
    }

    @Test("the modification date is reported, and it follows the file")
    func modificationDate() async throws {
        try await withDirectory { root in
            let backing = LocalFolderCacheBacking(directory: root)
            try backing.write(Data("x".utf8), as: "e")
            let written = try #require(try backing.read("e")?.modified)
            let old = written.addingTimeInterval(-86400)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent("e").path)
            let reread = try #require(try backing.read("e")?.modified)
            #expect(abs(reread.timeIntervalSince(old)) < 2)
        }
    }
}
