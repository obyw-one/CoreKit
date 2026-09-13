import Foundation

// MARK: - CountedDepthWalkRatchet

/// Scans a test tree for the counted-depth `#filePath` walk pattern that
/// shikki #1668 banned and spec one-path-resolution-ssot BR-PATH-02 makes
/// fleet-wide: a test takes `URL(fileURLWithPath: #filePath)` and chains
/// `.deletingLastPathComponent()` (or `.pathComponents.dropLast`) some
/// hand-counted number of times to locate the package. Moving the test
/// file silently changes what it points at.
///
/// The one legitimate implementation carries `// path-ssot: primitive` on
/// its file. Everything else is a hit — the ratchet consumes the marker,
/// never a filename allow-list, so a rename cannot bypass it.
public enum CountedDepthWalkRatchet {
    /// A single file:line the ratchet is unhappy about.
    public struct Hit: Sendable, Equatable, Hashable, CustomStringConvertible {
        public let file: String
        public let line: Int
        public init(file: String, line: Int) {
            self.file = file
            self.line = line
        }

        public var description: String {
            "\(file):\(line)"
        }
    }

    /// Whole-file exemption marker — the one implementing function carries
    /// this comment and is skipped.
    public static let primitiveMarker = "// path-ssot: primitive"

    /// Recursively walk `testsRoot` for `.swift` files and return one hit
    /// per offending `#filePath` line. Deterministically sorted by file
    /// then line so a failing ratchet reads the same on every run.
    public static func scan(testsRoot: URL) throws -> [Hit] {
        var hits: [Hit] = []
        guard
            let enumerator = FileManager.default.enumerator(
                at: testsRoot,
                includingPropertiesForKeys: nil
            ) else { return [] }
        while let obj = enumerator.nextObject() {
            guard let url = obj as? URL else { continue }
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            hits.append(contentsOf: scanText(text, at: url.path))
        }
        return hits.sorted { lhs, rhs in
            lhs.file == rhs.file ? lhs.line < rhs.line : lhs.file < rhs.file
        }
    }

    /// Pure-string version of the scanner — the primitive test targets and
    /// the unit tests both drive this so they never touch the disk.
    public static func scanText(_ text: String, at file: String) -> [Hit] {
        if text.contains(primitiveMarker) { return [] }
        let hasCountedCall =
            text.contains("deletingLastPathComponent(")
                || text.contains("pathComponents.dropLast")
        guard hasCountedCall else { return [] }
        var hits: [Hit] = []
        for (idx, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("#filePath")
        {
            hits.append(Hit(file: file, line: idx + 1))
        }
        return hits
    }
}

// MARK: - CountedDepthWalkBaseline

/// The shape of a per-package baseline JSON file
/// (`Tests/<Target>/…/Fixtures/counted-depth-walk-baseline.json`).
/// A ratchet holds counts DOWN: a file listed here may carry up to
/// `maxHits` counted-depth walks; a file NOT listed here MUST have zero
/// (spec one-path-resolution-ssot BR-PATH-07).
public struct CountedDepthWalkBaseline: Codable, Sendable, Equatable {
    public let generatedAt: String
    public let note: String
    /// Key = repo-relative path from package root; value = max allowed hits.
    public let files: [String: Int]

    public init(generatedAt: String, note: String, files: [String: Int]) {
        self.generatedAt = generatedAt
        self.note = note
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case note
        case files
    }
}
