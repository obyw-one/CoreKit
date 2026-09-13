import Foundation

// MARK: - TestScratch

/// The ONE way a test writes a temporary tree: under the package's own
/// `.tests/` directory (git-ignored), namespaced by a per-process `runID`
/// so two kagami runs never share a directory, and swept only through a
/// sentinel-guarded remove. Replaces `NSTemporaryDirectory()` fixtures
/// (BackendKit #2 review: "even not in our shikki root test folder!").
///
/// This is the seed of spec one-path-resolution-ssot W1a — `TestSandbox`
/// and `CountedDepthWalkRatchet` land there on top of this type; the API
/// below is the one that spec names, so consumers do not migrate twice.
public struct TestScratch: Sendable, Equatable {
    /// Segment that marks a scratch tree. Every scratch path contains
    /// `<testsRoot>/.test-runs/<runID>/`.
    public static let runsSegment = ".test-runs"

    /// Conventional `testsRoot` name under a package root.
    public static let testsDirectoryName = ".tests"

    /// Minted once per process — the namespace two concurrent test runs
    /// differ by.
    public static let processRunID: String = {
        let pid = ProcessInfo.processInfo.processIdentifier
        let nonce = UUID().uuidString.prefix(8).lowercased()
        return "\(pid)-\(nonce)"
    }()

    /// The root every scratch dir of this instance lives under.
    public let testsRoot: URL

    /// The run namespace in effect (defaults to `processRunID`).
    public let runID: String

    public init(testsRoot: URL, runID: String = TestScratch.processRunID) {
        self.testsRoot = testsRoot.standardizedFileURL
        self.runID = runID
    }

    /// `<packageRoot>/.tests` for the package that owns `testFile`.
    public static func forPackage(fromTestFile testFile: StaticString = #filePath) -> TestScratch {
        TestScratch(
            testsRoot: TestPackagePaths.packageRoot(fromTestFile: testFile)
                .appendingPathComponent(testsDirectoryName, isDirectory: true)
        )
    }

    /// `<testsRoot>/.test-runs/<runID>/<scope>` — not created.
    public func scratchRoot(scope: String) -> URL {
        testsRoot
            .appendingPathComponent(Self.runsSegment, isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true)
    }

    /// Creates and returns a fresh, unique directory under
    /// `scratchRoot(scope:)`. Each call yields a distinct directory.
    public func makeScratchDir(scope: String) throws -> URL {
        let dir = scratchRoot(scope: scope)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Removes `url` — only if it lies under this scratch's
    /// `<testsRoot>/.test-runs/<runID>/`. Anything else throws
    /// `PathSweepError.outsideSandbox`; symlinks are resolved before the
    /// check so a link into live data cannot smuggle a path in. On success,
    /// the removed path is logged to stderr — a sweep that runs in silence
    /// is a sweep that hides bugs (spec one-path-resolution-ssot BR-PATH-03).
    public func removeScratchDir(_ url: URL) throws {
        guard isInsideSandbox(url) else {
            throw PathSweepError.outsideSandbox(path: url.path)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            Self.logRemoval(url)
        }
    }

    private static func logRemoval(_ url: URL) {
        let line = "TestScratch.removeScratchDir: removed \(url.path)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// `true` when `url` (standardized, symlinks resolved) is strictly
    /// below `<testsRoot>/.test-runs/<runID>`.
    public func isInsideSandbox(_ url: URL) -> Bool {
        let sandbox = testsRoot
            .appendingPathComponent(Self.runsSegment, isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents
        let target = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard target.count > sandbox.count else { return false }
        return Array(target.prefix(sandbox.count)) == sandbox
    }
}
