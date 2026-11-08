import CoreKitTestSupport
import Foundation
import Testing

// MARK: - TestScratchTests

@Suite("TestScratch — package-local, run-namespaced, sentinel-guarded scratch dirs")
struct TestScratchTests {
    @Test("forPackage roots the scratch under <packageRoot>/.tests")
    func forPackageRoot() {
        let scratch = TestScratch.forPackage()
        let expected = TestPackagePaths.packageRoot()
            .appending(path: TestScratch.testsDirectoryName, directoryHint: .isDirectory)
            .standardizedFileURL
        #expect(scratch.testsRoot == expected)
        #expect(scratch.runID == TestScratch.processRunID)
    }

    @Test("makeScratchDir creates a unique directory under .test-runs/<runID>/<scope>")
    func makeScratchDirIsUniqueAndNamespaced() throws {
        let scratch = TestScratch.forPackage()
        let a = try scratch.makeScratchDir(scope: "test-scratch-tests")
        let b = try scratch.makeScratchDir(scope: "test-scratch-tests")
        defer {
            scratch.sweep(a)
            scratch.sweep(b)
        }
        #expect(a != b)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(a.pathComponents.contains(TestScratch.runsSegment))
        #expect(a.pathComponents.contains(scratch.runID))
        #expect(a.deletingLastPathComponent() == scratch.scratchRoot(scope: "test-scratch-tests"))
    }

    @Test("two runIDs never share a scratch root for the same scope")
    func runIDsIsolate() {
        let root = TestPackagePaths.packageRoot().appending(path: ".tests", directoryHint: .isDirectory)
        let one = TestScratch(testsRoot: root, runID: "run-a")
        let two = TestScratch(testsRoot: root, runID: "run-b")
        #expect(one.scratchRoot(scope: "x") != two.scratchRoot(scope: "x"))
    }

    @Test("removeScratchDir sweeps its own dirs and refuses anything else")
    func removeIsSentinelGuarded() throws {
        let scratch = TestScratch.forPackage()
        let mine = try scratch.makeScratchDir(scope: "sweep")
        try scratch.removeScratchDir(mine)
        #expect(!FileManager.default.fileExists(atPath: mine.path))

        // The package root, the tests root itself, and a sibling run are all outside.
        let outside = [
            TestPackagePaths.packageRoot(),
            scratch.testsRoot,
            TestScratch(testsRoot: scratch.testsRoot, runID: "someone-else").scratchRoot(scope: "sweep"),
            URL(fileURLWithPath: NSHomeDirectory()),
        ]
        for url in outside {
            #expect(throws: PathSweepError.outsideSandbox(path: url.path)) {
                try scratch.removeScratchDir(url)
            }
            #expect(!scratch.isInsideSandbox(url))
        }
    }

    @Test("sweep reports a refused cleanup instead of swallowing it, and stays silent on a clean one")
    func sweepReportsFailures() throws {
        let scratch = TestScratch.forPackage()
        let mine = try scratch.makeScratchDir(scope: "test-scratch-tests")
        var clean: [String] = []
        scratch.sweep(mine) { clean.append($0) }
        #expect(clean.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: mine.path))

        let outside = TestPackagePaths.packageRoot()
        var refused: [String] = []
        scratch.sweep(outside) { refused.append($0) }
        #expect(refused.count == 1)
        #expect(refused.first?.contains(outside.path) == true)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}
