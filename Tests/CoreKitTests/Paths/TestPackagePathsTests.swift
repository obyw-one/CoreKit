import CoreKitTestSupport
import Foundation
import Testing

// MARK: - TestPackagePathsTests

@Suite("TestPackagePaths — nearest-marker walk, not counted depth (T-01)")
struct TestPackagePathsTests {
    @Test("packageRoot() from this test file resolves to a directory with Package.swift")
    func packageRootFindsMarker() {
        let root = TestPackagePaths.packageRoot()
        let manifest = root.appending(path: "Package.swift", directoryHint: .notDirectory).path
        #expect(FileManager.default.fileExists(atPath: manifest))
    }

    @Test("packageRoot returns the SAME package root from callers at different depths")
    func packageRootIsMarkerBasedNotCountedDepth() throws {
        // Synthesize two fake test files under the same fake package, at
        // different depths. `packageRoot(fromFilePath:)` must return the
        // same root for both — that is the property a counted-depth walk
        // would silently violate.
        let fakePackage = try makeFakePackage()
        defer { try? FileManager.default.removeItem(at: fakePackage) }

        let deepFile = fakePackage.appending(path: "Tests/A/B/C/DeepTest.swift", directoryHint: .notDirectory)
        let shallowFile = fakePackage.appending(path: "Tests/A/ShallowTest.swift", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: deepFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: shallowFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: deepFile.path, contents: Data())
        FileManager.default.createFile(atPath: shallowFile.path, contents: Data())

        let deepRoot = TestPackagePaths.packageRoot(fromFilePath: deepFile.path)
        let shallowRoot = TestPackagePaths.packageRoot(fromFilePath: shallowFile.path)
        let expected = fakePackage.standardizedFileURL

        #expect(deepRoot.standardizedFileURL == expected)
        #expect(shallowRoot.standardizedFileURL == expected)
        #expect(deepRoot == shallowRoot)
    }

    @Test("sourcesRoot(ofModule:) composes as <packageRoot>/Sources/<module>")
    func sourcesRootOfModuleComposes() {
        let root = TestPackagePaths.packageRoot()
        let expected =
            root
                .appending(path: "Sources", directoryHint: .isDirectory)
                .appending(path: "CoreKit", directoryHint: .isDirectory)
        #expect(TestPackagePaths.sourcesRoot(ofModule: "CoreKit") == expected)
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    // MARK: - Fixture

    private func makeFakePackage() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "TestPackagePathsTests-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let manifest = base.appending(path: "Package.swift", directoryHint: .notDirectory)
        FileManager.default.createFile(atPath: manifest.path, contents: Data("// swift-tools-version: 6.0\n".utf8))
        return base
    }
}
