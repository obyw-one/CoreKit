import CoreKit
import Foundation
import Testing

// MARK: - PathSegmentTests

@Suite("PathSegment — a validated name, never a path (BR-RP-04)")
struct PathSegmentTests {

    private static let slash = PathSeparator.posix.rawValue
    private static let backslash = PathSeparator.windows.rawValue

    private static let withSeparators: [String] = {
        let parts = ["a", "b"]
        return [
            parts.joined(separator: slash), parts.joined(separator: backslash),
            slash + "etc", "x" + slash,
        ]
    }()

    private static let climbingIds: [String] = {
        let up = PathVocabulary.parentComponent
        return [
            [up, up, "flows"].joined(separator: slash),
            [up, "x"].joined(separator: backslash),
        ]
    }()

    private static let slugInputs: [String] = ["", "..", ".", slash, "   ", "<>"]

    @Test("names the fleet really uses are accepted", arguments: [
        "plans.json", ".tests", ".manifest.json", "pr-7.dossier.json", "7f3a", "mac studio", "été.json",
    ])
    func acceptsRealNames(_ raw: String) throws {
        #expect(try PathSegment(raw).rawValue == raw)
    }

    @Test("empty is refused")
    func refusesEmpty() {
        let empty = String()
        #expect(throws: VirtualPathError.emptySegment) { try PathSegment(empty) }
    }

    @Test("`.` and `..` are refused as traversal, not as names", arguments: [".", ".."])
    func refusesTraversal(_ raw: String) {
        #expect(throws: VirtualPathError.traversalSegment(raw)) { try PathSegment(raw) }
    }

    @Test("a separator of either platform is refused", arguments: PathSegmentTests.withSeparators)
    func refusesSeparators(_ raw: String) {
        #expect(throws: VirtualPathError.separatorInSegment(raw)) { try PathSegment(raw) }
    }

    @Test("a climbing id is refused the moment the owner builds its segment", arguments: PathSegmentTests.climbingIds)
    func refusesClimbingId(_ raw: String) {
        #expect(throws: VirtualPathError.self) { try PathSegment(raw) }
    }

    @Test("control characters and the platform-reserved set are refused", arguments: [
        "a\u{0}b", "a\nb", "a\tb", "a\u{7F}b", "a<b", "a>b", "a:b", "a\"b", "a|b", "a?b", "a*b",
    ])
    func refusesForbiddenCharacters(_ raw: String) {
        #expect(throws: VirtualPathError.self) { try PathSegment(raw) }
        do {
            _ = try PathSegment(raw)
        } catch {
            guard case .forbiddenCharacter(let segment, _) = error else {
                Issue.record("expected forbiddenCharacter, got \(error)")
                return
            }
            #expect(segment == raw)
        }
    }

    @Test("a name a platform would silently rewrite is refused", arguments: [" a", "a ", "a.", "...", "\u{A0}a"])
    func refusesUnstableBoundary(_ raw: String) {
        #expect(throws: VirtualPathError.self) { try PathSegment(raw) }
    }

    @Test("the length limit is 255 UTF-8 bytes")
    func lengthLimit() throws {
        #expect(try PathSegment(String(repeating: "a", count: 255)).rawValue.utf8.count == 255)
        #expect(throws: VirtualPathError.segmentTooLong(length: 256, limit: 255)) {
            try PathSegment(String(repeating: "a", count: 256))
        }
        // Bytes, not characters: 128 two-byte characters are 256 bytes.
        #expect(throws: VirtualPathError.self) { try PathSegment(String(repeating: "é", count: 128)) }
    }

    @Test("a literal is a segment")
    func literal() {
        let segment: PathSegment = "plans.json"
        #expect(segment.rawValue == "plans.json")
        #expect(segment.description == "plans.json")
    }

    // MARK: slug

    @Test("slug turns a branch into one readable grouping segment")
    func slugBranch() throws {
        let feature = ["feat", "new thing"].joined(separator: Self.slash)
        #expect(try PathSegment.slug(from: feature).rawValue == "feat-new-thing")
        let epic = ["epic", "d3f8a1b2-resource-layer"].joined(separator: Self.slash)
        #expect(try PathSegment.slug(from: epic).rawValue == "epic-d3f8a1b2-resource-layer")
        let doubled = ["a", "", "b  c"].joined(separator: Self.slash)
        #expect(try PathSegment.slug(from: doubled).rawValue == "a-b-c")
        let wrapped = [ "", "lead", ""].joined(separator: Self.slash)
        #expect(try PathSegment.slug(from: wrapped).rawValue == "lead")
    }

    @Test("a slug can never be a traversal or empty", arguments: PathSegmentTests.slugInputs)
    func slugRefusesNothing(_ raw: String) {
        #expect(throws: VirtualPathError.self) { try PathSegment.slug(from: raw) }
    }

    @Test("a slug of a hostile branch cannot climb")
    func slugCannotClimb() throws {
        let hostile = [PathVocabulary.parentComponent, PathVocabulary.parentComponent, "etc"]
            .joined(separator: Self.slash)
        let slug = try PathSegment.slug(from: hostile)
        #expect(slug.rawValue == "etc")
        #expect(!slug.rawValue.contains(Self.slash))
    }

    // MARK: Codable

    @Test("round-trips through JSON as a bare string")
    func codableRoundTrip() throws {
        let segment: PathSegment = "state.json"
        let data = try JSONEncoder().encode(segment)
        #expect(String(bytes: data, encoding: .utf8) == "\"state.json\"")
        #expect(try JSONDecoder().decode(PathSegment.self, from: data) == segment)
    }

    @Test("decoding an invalid segment fails instead of constructing one")
    func decodeRefusesInvalid() {
        let hostile = Data(("\"" + [PathVocabulary.parentComponent, "x"].joined(separator: Self.slash) + "\"").utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PathSegment.self, from: hostile) }
    }
}
