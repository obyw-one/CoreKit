import Foundation

// MARK: - TestSandbox

/// A one-shot, freshly-minted filesystem sandbox for a test: mint a fresh
/// directory under `<testsRoot>/.test-runs/<uuid>/`, hand back its root
/// and a `sweep()` that only ever deletes THIS mint. It is a **factory**,
/// not a second `PathProviding` conformer — the whole point of spec
/// one-path-resolution-ssot BR-PATH-02 is that prod and tests differ
/// **only** by an injected root, not by the type behind the seam.
///
/// In W1 the returned value carries the sandbox `root` URL and a sweeper.
/// In W2 (when `ProdPaths` lands in CoreKit runtime) `make(under:)` gains
/// a `paths: ProdPaths` slot rooted at `root`; today the `root` is the
/// primitive tests can build on.
public struct TestSandbox: Sendable {
    /// The freshly-minted sandbox root — `<testsRoot>/.test-runs/<sandboxID>/`.
    public let root: URL

    /// The UUID segment minted for this sandbox. Every path this sandbox
    /// authorizes for sweep MUST have `sandboxID` immediately after
    /// `.test-runs` in its component list.
    public let sandboxID: String

    /// Mints a fresh sandbox directory at `<testsRoot>/.test-runs/<uuid>/`
    /// and creates it on disk. Throws on filesystem errors — no `try?`.
    public static func make(under testsRoot: URL) throws -> TestSandbox {
        let sandboxID = UUID().uuidString.lowercased()
        let root = testsRoot.standardizedFileURL
            .appendingPathComponent(TestScratch.runsSegment, isDirectory: true)
            .appendingPathComponent(sandboxID, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return TestSandbox(root: root, sandboxID: sandboxID)
    }

    /// Test-facing initializer for the "aim a bad root" case of T-04:
    /// callers can construct a sandbox whose `root` does NOT carry the
    /// sentinel and verify that `sweep()` refuses it. `make(under:)` is the
    /// production factory; this init exists for the negative test.
    public init(root: URL, sandboxID: String) {
        self.root = root.standardizedFileURL
        self.sandboxID = sandboxID
    }

    /// Removes `root` — but only if its standardized, symlink-resolved path
    /// contains `.test-runs/<sandboxID>` (the mint that authorized this
    /// sandbox). Anything else throws `PathSweepError.outsideSandbox`.
    /// Throws on filesystem errors. Logs to stderr on success.
    public func sweep() throws {
        try checkSentinel()
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
            Self.logSweep(root)
        }
    }

    /// `true` when `root` (standardized, symlinks resolved) carries the
    /// mint sentinel `.test-runs/<sandboxID>`. `sweep()` uses this; tests
    /// can call it directly.
    public func hasSentinel() -> Bool {
        let comps = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard let runsIdx = comps.firstIndex(of: TestScratch.runsSegment) else { return false }
        let idIdx = runsIdx + 1
        guard idIdx < comps.count, comps[idIdx] == sandboxID else { return false }
        return true
    }

    private func checkSentinel() throws {
        guard hasSentinel() else {
            throw PathSweepError.outsideSandbox(path: root.path)
        }
    }

    private static func logSweep(_ url: URL) {
        let line = "TestSandbox.sweep: removed \(url.path)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
