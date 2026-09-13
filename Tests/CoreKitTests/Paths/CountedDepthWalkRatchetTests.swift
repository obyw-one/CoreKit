import CoreKitTestSupport
import Foundation
import Testing

// MARK: - CountedDepthWalkRatchetTests

/// The ratchet MUST NOT self-trigger, so this file never contains the raw
/// pattern strings — the sample sources below are assembled from string
/// interpolation so the source of THIS file carries neither
/// `#filePath` nor `deletingLastPathComponent(` as a substring.
@Suite("CountedDepthWalkRatchet — the counted-depth #filePath walk ratchet (T-08)")
struct CountedDepthWalkRatchetTests {
    // Interpolated tokens so this file never carries the raw substrings the
    // scanner keys on. Concatenation happens at runtime; the source bytes
    // do not spell either forbidden pattern.
    private static let hash = "#"
    private static let filePathToken = "\(hash)filePath"
    private static let delCall = "\("deletingLastPathComponent")("
    private static let dropLastToken = "pathComponents.\("dropLast")"

    @Test("scanText reports the #filePath line when the file also walks with deletingLastPathComponent(")
    func detectsDeletingLastPathComponentWalk() {
        let source = """
        import Foundation
        enum Silly {
            static func root() -> URL {
                let f = URL(fileURLWithPath: \(Self.filePathToken))
                return f.\(Self.delCall)).\(Self.delCall))
            }
        }
        """
        let hits = CountedDepthWalkRatchet.scanText(source, at: "Fake.swift")
        #expect(hits == [CountedDepthWalkRatchet.Hit(file: "Fake.swift", line: 4)])
    }

    @Test("scanText reports the #filePath line when the file walks with pathComponents.dropLast")
    func detectsPathComponentsDropLast() {
        let source = """
        let file = URL(fileURLWithPath: \(Self.filePathToken))
        let bits = file.\(Self.dropLastToken)(2)
        """
        let hits = CountedDepthWalkRatchet.scanText(source, at: "Fake.swift")
        #expect(hits == [CountedDepthWalkRatchet.Hit(file: "Fake.swift", line: 1)])
    }

    @Test("scanText does NOT report files that use #filePath without any counted-depth call")
    func skipsFilesWithoutCountedWalk() {
        let source = """
        let file = URL(fileURLWithPath: \(Self.filePathToken))
        // no walk here — TestPackagePaths does it for us
        """
        let hits = CountedDepthWalkRatchet.scanText(source, at: "Ok.swift")
        #expect(hits.isEmpty)
    }

    @Test("scanText exempts files carrying the primitive marker")
    func primitiveMarkerExempts() {
        let source = """
        // path-ssot: primitive
        let file = URL(fileURLWithPath: \(Self.filePathToken))
        let root = file.\(Self.delCall))
        """
        let hits = CountedDepthWalkRatchet.scanText(source, at: "Primitive.swift")
        #expect(hits.isEmpty)
    }

    @Test("scan(testsRoot:) reports every offending #filePath line, deterministically sorted")
    func scanReportsSortedHits() throws {
        // A miniature tree under a fresh sandbox — the scanner walks the
        // whole subtree and reports one hit per pattern line, sorted by
        // file then line.
        let testsRoot = TestPackagePaths
            .packageRoot()
            .appendingPathComponent(TestScratch.testsDirectoryName, isDirectory: true)
        let sandbox = try TestSandbox.make(under: testsRoot)
        defer { try? sandbox.sweep() }

        let a = sandbox.root.appendingPathComponent("A.swift")
        let b = sandbox.root.appendingPathComponent("nested/B.swift")
        try FileManager.default.createDirectory(
            at: b.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: a.path,
            contents: Data("""
            let x = URL(fileURLWithPath: \(Self.filePathToken))
            let y = x.\(Self.delCall))
            """.utf8)
        )
        FileManager.default.createFile(
            atPath: b.path,
            contents: Data("""
            // preamble
            let x = URL(fileURLWithPath: \(Self.filePathToken))
            let y = x.\(Self.delCall))
            let z = URL(fileURLWithPath: \(Self.filePathToken))
            """.utf8)
        )

        let hits = try CountedDepthWalkRatchet.scan(testsRoot: sandbox.root)

        #expect(hits.count == 3)
        #expect(hits[0].file.hasSuffix("A.swift") && hits[0].line == 1)
        #expect(hits[1].file.hasSuffix("B.swift") && hits[1].line == 2)
        #expect(hits[2].file.hasSuffix("B.swift") && hits[2].line == 4)
    }

    // MARK: - The CoreKit ratchet (baseline 0)

    @Test("CoreKit's test tree has zero counted-depth walks — baseline is empty (T-08 CoreKit)")
    func coreKitTestsAreClean() throws {
        let testsRoot = TestPackagePaths
            .packageRoot()
            .appendingPathComponent("Tests", isDirectory: true)
            .appendingPathComponent("CoreKitTests", isDirectory: true)
        let hits = try CountedDepthWalkRatchet.scan(testsRoot: testsRoot)
        #expect(
            hits.isEmpty,
            "CoreKit baseline is 0. Offenders: \(hits.map(\.description).joined(separator: ", "))"
        )
    }

    @Test("baseline file on disk decodes to an empty file map")
    func baselineDecodesEmpty() throws {
        let baselineURL = TestPackagePaths
            .packageRoot()
            .appendingPathComponent("Tests", isDirectory: true)
            .appendingPathComponent("CoreKitTests", isDirectory: true)
            .appendingPathComponent("Paths", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("counted-depth-walk-baseline.json")
        let data = try Data(contentsOf: baselineURL)
        let baseline = try JSONDecoder().decode(CountedDepthWalkBaseline.self, from: data)
        #expect(baseline.files.isEmpty)
    }
}
