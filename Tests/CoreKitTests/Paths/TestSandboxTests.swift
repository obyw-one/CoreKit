import CoreKitTestSupport
import Foundation
import Testing

// MARK: - TestSandboxTests

@Suite("TestSandbox — one-shot minted scratch with sentinel-guarded sweep (T-04)")
struct TestSandboxTests {
    /// The tests-root for these tests: `<packageRoot>/.tests` — the same
    /// convention `TestScratch.forPackage()` uses. Git-ignored.
    private static let testsRoot =
        TestPackagePaths
            .packageRoot()
            .appendingPathComponent(TestScratch.testsDirectoryName, isDirectory: true)

    @Test("make(under:) mints a directory under <testsRoot>/.test-runs/<uuid>/ and creates it")
    func makeMintsAndCreatesRoot() throws {
        let sandbox = try TestSandbox.make(under: Self.testsRoot)
        defer { try? sandbox.sweep() }

        let comps = sandbox.root.pathComponents
        #expect(comps.contains(TestScratch.runsSegment))
        #expect(comps.last == sandbox.sandboxID)
        #expect(FileManager.default.fileExists(atPath: sandbox.root.path))
    }

    @Test("sweep() removes the sandbox subtree it minted")
    func sweepRemovesTheMintedSubtree() throws {
        let sandbox = try TestSandbox.make(under: Self.testsRoot)
        // Populate it — sweep must take the whole subtree with it.
        let child = sandbox.root.appendingPathComponent("payload.txt")
        FileManager.default.createFile(atPath: child.path, contents: Data("payload".utf8))
        #expect(FileManager.default.fileExists(atPath: child.path))

        try sandbox.sweep()

        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path))
        #expect(!FileManager.default.fileExists(atPath: child.path))
    }

    @Test("sweep() throws PathSweepError.outsideSandbox when the root lacks the .test-runs/<sandboxID> sentinel")
    func sweepRefusesOutsideSandbox() throws {
        // A "test-double" sandbox aimed at $HOME — no .test-runs sentinel,
        // no minted uuid segment. sweep MUST refuse and NOT touch anything.
        let bad = TestSandbox(root: URL(fileURLWithPath: NSHomeDirectory()), sandboxID: UUID().uuidString.lowercased())
        #expect(!bad.hasSentinel())
        #expect(throws: PathSweepError.self) {
            try bad.sweep()
        }
        // The home directory still exists — sweep did not touch it.
        #expect(FileManager.default.fileExists(atPath: NSHomeDirectory()))
    }

    @Test("sweep() throws when a sandbox is built with a sandboxID that does not match the mint segment")
    func sweepRefusesMismatchedSandboxID() throws {
        let good = try TestSandbox.make(under: Self.testsRoot)
        defer { try? good.sweep() }
        // Same root but with a different sandboxID — the sentinel check
        // walks `.test-runs` and asserts the NEXT component matches.
        let mismatched = TestSandbox(root: good.root, sandboxID: "someone-elses-id")
        #expect(!mismatched.hasSentinel())
        #expect(throws: PathSweepError.self) {
            try mismatched.sweep()
        }
        // `good.root` is untouched — the good sandbox still finds its dir.
        #expect(FileManager.default.fileExists(atPath: good.root.path))
    }

    @Test("two sandboxes minted under the same testsRoot get independent roots (T-05 parallel isolation)")
    func twoSandboxesIsolate() throws {
        let a = try TestSandbox.make(under: Self.testsRoot)
        let b = try TestSandbox.make(under: Self.testsRoot)
        defer {
            try? a.sweep()
            try? b.sweep()
        }
        #expect(a.root != b.root)
        #expect(a.sandboxID != b.sandboxID)
    }
}
