import CoreKit
import Foundation
import Testing

/// obyw-one/CoreKit#21 review: the JSON helpers must surface their errors —
/// the optional getters only ever served a log one-liner.
@Suite("JSON helpers — throwing API, no swallowed errors")
struct JSONHelpersTests {
    private struct Sample: Codable, Equatable {
        let id: Int
        let path: String
    }

    @Test("prettyJSON() encodes and the result decodes back to the same value")
    func prettyRoundTrip() throws {
        let value = Sample(id: 7, path: "a/b")
        let json = try value.prettyJSON()
        #expect(json.contains("\n"), "pretty output is multi-line")
        let back = try JSONDecoder().decode(Sample.self, from: Data(json.utf8))
        #expect(back == value)
    }

    @Test("compactJSON() keeps slashes unescaped and is single-line")
    func compactKeepsSlashes() throws {
        let json = try Sample(id: 1, path: "a/b").compactJSON()
        #expect(json.contains("a/b"))
        #expect(!json.contains("\\/"))
        #expect(!json.contains("\n"))
    }

    @Test("Data.prettyJSON() throws on bytes that are not JSON — the caller decides, nothing is swallowed")
    func dataPrettyThrowsOnGarbage() {
        #expect(throws: (any Error).self) {
            try Data("not json".utf8).prettyJSON()
        }
    }

    @Test("Data.prettyJSON() pretty-prints valid JSON bytes")
    func dataPrettyPrints() throws {
        let pretty = try Data(#"{"a":1}"#.utf8).prettyJSON()
        #expect(pretty.contains("\"a\" : 1"))
    }
}
