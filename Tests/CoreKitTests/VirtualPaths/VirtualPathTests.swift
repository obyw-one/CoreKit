import CoreKit
import CoreKitTestSupport
import Foundation
import Testing

// MARK: - VirtualPathTests

@Suite("VirtualPath — components, rendered only at the boundary")
struct VirtualPathTests {

    private static let slash = PathSeparator.posix.rawValue

    private static let malformedWireForms: [String] = {
        let up = PathVocabulary.parentComponent
        let here = PathVocabulary.currentComponent
        return [
            ["a", "", "b"].joined(separator: slash),
            slash + "a",
            "a" + slash,
            ["a", up, "b"].joined(separator: slash),
            ["a", here, "b"].joined(separator: slash),
        ]
    }()

    private func path(_ names: String...) throws -> VirtualPath {
        VirtualPath(try names.map { try PathSegment($0) })
    }

    @Test("the separator vocabulary is one grapheme per case and posix on the wire")
    func separatorVocabulary() {
        for separator in PathSeparator.allCases {
            #expect(separator.rawValue.count == 1)
            #expect(String(separator.character) == separator.rawValue)
        }
        #expect(PathVocabulary.wireSeparator == PathSeparator.posix.rawValue)
        #expect(PathVocabulary.parentComponent == "..")
        #expect(PathVocabulary.currentComponent == ".")
        #expect(PathSeparator.native.rawValue == PathVocabulary.separator)
    }

    @Test("renders with the posix separator by default and the windows one on request")
    func rendering() throws {
        let value = try path("flows", "7f3a", "7f3a-metadata.json")
        #expect(value.rendered() == ["flows", "7f3a", "7f3a-metadata.json"].joined(separator: Self.slash))
        #expect(value.rendered(separator: .windows)
            == ["flows", "7f3a", "7f3a-metadata.json"].joined(separator: PathSeparator.windows.rawValue))
        #expect(value.description == value.rendered())
        #expect(VirtualPath.empty.rendered().isEmpty)
    }

    @Test("a rendered path parses back to the same components")
    func parseRoundTrip() throws {
        let value = try path("state", "ai-routing", "ledger.json")
        #expect(try VirtualPath(parsing: value.rendered()) == value)
        #expect(try VirtualPath(parsing: value.rendered(separator: .windows), separator: .windows) == value)
        #expect(try VirtualPath(parsing: "").isEmpty)
    }

    @Test("parsing refuses a malformed wire form instead of normalising it", arguments: VirtualPathTests.malformedWireForms)
    func parseRefuses(_ wire: String) {
        #expect(throws: VirtualPathError.self) { try VirtualPath(parsing: wire) }
    }

    @Test("a nested node written as one path equals the same node built with child()")
    func parsedNodeEqualsChainedNode() throws {
        let nested = ["state", "ai-routing"].joined(separator: Self.slash)
        let parsed = VirtualNode(path: try VirtualPath(parsing: nested))
        let chained = VirtualNode(PathSegment(stringLiteral: "state")).child(PathSegment(stringLiteral: "ai-routing"))
        #expect(parsed == chained)
        #expect(parsed.path.segments.count == 2)
        #expect(VirtualPath(stringLiteral: nested) == parsed.path)
    }

    @Test("a path refuses a traversal, a padded component and a foreign separator instead of reading them as one name")
    func parseRefusesUnsafeAuthoredPaths() {
        let up = PathVocabulary.parentComponent
        let unsafe = [
            [up, "escape"].joined(separator: Self.slash),
            ["state", up].joined(separator: Self.slash),
            ["state", "ai-routing "].joined(separator: Self.slash),
            ["state", "ai-routing"].joined(separator: PathSeparator.windows.rawValue),
        ]
        for wire in unsafe {
            #expect(throws: VirtualPathError.self) { try VirtualPath(parsing: wire) }
        }
    }

    @Test("composition and queries")
    func composition() throws {
        let node = try path("flows")
        let full = node.appending(PathSegment("7f3a")).appending(try path("a.json", "b.json"))
        #expect(full.segments.count == 4)
        #expect(full.last?.rawValue == "b.json")
        #expect(full.parent == (try path("flows", "7f3a", "a.json")))
        #expect(full.hasPrefix(node))
        #expect(!node.hasPrefix(full))
        #expect(full.hasPrefix(.empty))
        #expect(VirtualPath.empty.parent == nil)
        #expect(VirtualPath.empty.last == nil)
    }

    @Test("a prefix is componentwise, never textual")
    func prefixIsComponentwise() throws {
        let short = try path("flow")
        let long = try path("flows", "x")
        #expect(!long.hasPrefix(short))
    }

    @Test("fileURL builds a URL component by component under the base")
    func fileURL() throws {
        let scratch = TestScratch.forPackage()
        let base = try scratch.makeScratchDir(scope: "virtual-path-file-url")
        defer { try? scratch.removeScratchDir(base) }
        let url = try path("state", "ledger.json").fileURL(under: base)
        #expect(url.lastPathComponent == "ledger.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "state")
        #expect(PathContainment.isContained(url, in: base))
        // Resolve-only: building the URL created nothing.
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Codable is an array of component strings and validates on decode")
    func codable() throws {
        let value = try path("a", "b")
        let data = try JSONEncoder().encode(value)
        #expect(String(bytes: data, encoding: .utf8) == "[\"a\",\"b\"]")
        #expect(try JSONDecoder().decode(VirtualPath.self, from: data) == value)
        let hostile = Data("[\"a\",\"..\"]".utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(VirtualPath.self, from: hostile) }
    }
}
