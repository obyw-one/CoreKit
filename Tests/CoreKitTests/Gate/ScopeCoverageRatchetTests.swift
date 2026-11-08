import CoreKit
import CoreKitTestSupport
import Foundation
import Testing

// MARK: - ScopeRegistry

/// The scopes `.kagami/scopes.override.toml` declares, read just far enough to answer one question:
/// which scope runs which test file. `kagami test --all` resolves DECLARED scopes, so a test file no
/// scope's glob matches is never run, and the gate stays green over it.
private struct DeclaredScope: Equatable {
    let name: String
    let filePatterns: [String]
    let typePatterns: [String]
}

private enum ScopeRegistry {

    static func parse(_ text: String) -> [DeclaredScope] {
        text.components(separatedBy: "[[scopes]]").dropFirst().compactMap { block in
            guard let name = values(of: "name", in: block, isList: false).first else { return nil }
            return DeclaredScope(
                name: name,
                filePatterns: values(of: "test_file_patterns", in: block, isList: true),
                typePatterns: values(of: "type_patterns", in: block, isList: true))
        }
    }

    private static func values(of key: String, in block: String, isList: Bool) -> [String] {
        let pattern = isList ? "(?m)^\(key) = \\[([^\\]]*)\\]" : "(?m)^\(key) = \"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
            let range = Range(match.range(at: 1), in: block)
        else { return [] }
        let body = String(block[range])
        guard isList else { return [body] }
        guard let quoted = try? NSRegularExpression(pattern: "\"([^\"]*)\"") else { return [] }
        return quoted.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap {
            Range($0.range(at: 1), in: body).map { String(body[$0]) }
        }
    }
}

// MARK: - Census

private struct Census: Equatable {
    var orphans: [String] = []
    var shared: [String: [String]] = [:]
    var typesOutsideTheirScope: [String] = []
}

private enum ScopeCoverage {

    /// `**/` is any directory prefix (or none), `**` any characters, `*` any characters within one component.
    static func matches(_ pattern: String, _ path: String) -> Bool {
        let separator = PathVocabulary.wireSeparator
        var out = "^"
        var rest = Substring(pattern)
        while let head = rest.first {
            if rest.hasPrefix("**" + separator) {
                out += "(?:.*\(NSRegularExpression.escapedPattern(for: separator)))?"
                rest = rest.dropFirst(3)
            } else if rest.hasPrefix("**") {
                out += ".*"
                rest = rest.dropFirst(2)
            } else if head == "*" {
                out += "[^\(NSRegularExpression.escapedPattern(for: separator))]*"
                rest = rest.dropFirst()
            } else {
                out += NSRegularExpression.escapedPattern(for: String(head))
                rest = rest.dropFirst()
            }
        }
        return path.range(of: out + "$", options: .regularExpression) != nil
    }

    /// `files` maps a repository-relative path to the `*Tests` types it declares.
    static func census(files: [String: [String]], scopes: [DeclaredScope]) -> Census {
        var census = Census()
        for (path, types) in files.sorted(by: { $0.key < $1.key }) {
            let owners = scopes.filter { scope in scope.filePatterns.contains { matches($0, path) } }
            if owners.isEmpty { census.orphans.append(path) }
            if owners.count > 1 { census.shared[path] = owners.map(\.name) }
            guard let owner = owners.first else { continue }
            for type in types where !owner.typePatterns.contains(where: { type.contains($0) }) {
                census.typesOutsideTheirScope.append("\(path): \(type) is not in \(owner.name)'s type_patterns")
            }
        }
        return census
    }
}

// MARK: - ScopeCoverageRatchetTests

@Suite("Scope coverage — every test file belongs to exactly one declared scope, and its suites are in that scope's filter")
struct ScopeCoverageRatchetTests {

    private static func repositoryFiles() throws -> [String: [String]] {
        let root = TestPackagePaths.packageRoot()
        let tests = root.appending(path: "Tests", directoryHint: .isDirectory)
        guard let walker = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil) else { return [:] }
        let declaration = try NSRegularExpression(
            pattern: "(?m)^\\s*(?:private |fileprivate |public )?(?:final )?(?:struct|class|actor|enum) (\\w+Tests)\\b")
        var files: [String: [String]] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = Array(url.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count))
                .joined(separator: PathVocabulary.wireSeparator)
            let text = try String(contentsOf: url, encoding: .utf8)
            files[relative] = declaration.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            }
        }
        return files
    }

    private static func declaredScopes() throws -> [DeclaredScope] {
        let registry = TestPackagePaths.packageRoot()
            .appending(path: ".kagami", directoryHint: .isDirectory)
            .appending(path: "scopes.override.toml", directoryHint: .notDirectory)
        return ScopeRegistry.parse(try String(contentsOf: registry, encoding: .utf8))
    }

    @Test("the real registry: no orphan test file, no file owned twice, no suite outside its scope's filter")
    func realRegistry() throws {
        let files = try Self.repositoryFiles()
        let scopes = try Self.declaredScopes()
        #expect(files.count > 20, "the walker found too few test files: locator drift?")
        #expect(scopes.count > 10, "the registry parse found too few scopes")
        let census = ScopeCoverage.census(files: files, scopes: scopes)
        #expect(census.orphans.isEmpty, "test files no scope runs: \(census.orphans)")
        #expect(census.shared.isEmpty, "test files owned by several scopes: \(census.shared)")
        #expect(census.typesOutsideTheirScope.isEmpty, "suites their scope's type_patterns never select: \(census.typesOutsideTheirScope)")
    }

    // MARK: The detector itself

    private let scopes = [
        DeclaredScope(name: "A", filePatterns: ["**/T/A/**.swift"], typePatterns: ["AlphaTests"]),
        DeclaredScope(name: "B", filePatterns: ["**/T/*.swift", "**/T/B/**.swift"], typePatterns: ["BetaTests"]),
    ]

    @Test("a file no scope matches is an orphan")
    func detectsOrphan() {
        let census = ScopeCoverage.census(files: ["Tests/T/C/Lost.swift": ["LostTests"]], scopes: scopes)
        #expect(census.orphans == ["Tests/T/C/Lost.swift"])
    }

    @Test("a file two scopes match is shared")
    func detectsDoubleOwner() {
        let both = [scopes[0], DeclaredScope(name: "Greedy", filePatterns: ["**/T/**.swift"], typePatterns: ["AlphaTests"])]
        let census = ScopeCoverage.census(files: ["Tests/T/A/X.swift": ["AlphaTests"]], scopes: both)
        #expect(census.shared == ["Tests/T/A/X.swift": ["A", "Greedy"]])
    }

    @Test("a suite its owning scope's type_patterns do not select is reported")
    func detectsSilentSuite() {
        let census = ScopeCoverage.census(files: ["Tests/T/A/X.swift": ["AlphaTests", "ForgottenTests"]], scopes: scopes)
        #expect(census.typesOutsideTheirScope.count == 1)
        #expect(census.typesOutsideTheirScope.first?.contains("ForgottenTests") == true)
    }

    @Test("a covered tree is clean, and a single-star glob does not reach into subfolders")
    func cleanAndGlobSemantics() {
        let clean = ScopeCoverage.census(
            files: ["Tests/T/Top.swift": ["BetaTests"], "Tests/T/A/Deep.swift": ["AlphaTests"]], scopes: scopes)
        #expect(clean == Census())
        #expect(ScopeCoverage.matches("**/T/*.swift", "Tests/T/Top.swift"))
        #expect(!ScopeCoverage.matches("**/T/*.swift", "Tests/T/Sub/Deep.swift"))
        #expect(ScopeCoverage.matches("**/T/**.swift", "Tests/T/Sub/Deep.swift"))
    }

    @Test("the registry parser reads names, file patterns and type patterns")
    func parser() {
        let parsed = ScopeRegistry.parse("""
        # c
        [[scopes]]
        name = "One"
        type_patterns = ["XTests", "YTests"]
        test_file_patterns = ["**/X/**.swift"]

        [[scopes]]
        name = "Two"
        type_patterns = ["ZTests"]
        test_file_patterns = ["**/Z/*.swift", "**/W/**.swift"]
        """)
        #expect(parsed == [
            DeclaredScope(name: "One", filePatterns: ["**/X/**.swift"], typePatterns: ["XTests", "YTests"]),
            DeclaredScope(name: "Two", filePatterns: ["**/Z/*.swift", "**/W/**.swift"], typePatterns: ["ZTests"]),
        ])
    }
}
