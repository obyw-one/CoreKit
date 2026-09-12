import Foundation

// MARK: - TaskDeadlineRatchet

/// The one shape every consumer's `TaskDeadline` ratchet uses: scan
/// a sources tree and return every `Task.sleep(for:` occurrence.
/// Consumers assert `clockBasedSleeps(in: <their Sources>)` is empty
/// in a test target so the abort class BR-CKT-02 chased away never
/// creeps back in.
///
/// This target ships as its own library so kits outside CoreKit (and
/// CoreKit itself) share one implementation instead of copy-pasting
/// a scanner into every kit's test suite.
public enum TaskDeadlineRatchet {
    /// Returns one "path:line: text" string per clock-based sleep
    /// found under `sourcesRoot`. Empty means the tree is clean.
    /// Line comments are skipped so the ratchet does not flag the
    /// pattern's own mention in doc-comments.
    public static func clockBasedSleeps(in sourcesRoot: URL) -> [String] {
        var hits: [String] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return hits
        }
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if trimmed.contains("Task.sleep(for") {
                    hits.append("\(url.path):\(index + 1): \(trimmed)")
                }
            }
        }
        return hits.sorted()
    }
}
