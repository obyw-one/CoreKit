import CoreKit
import CoreKitTestSupport
import Foundation
import Testing

/// The one coding key the lenient models need, at FILE scope.
///
/// It was `enum CodingKeys` inside each model, which made
/// `@Suite struct` -> `struct` -> `enum` three levels and tripped SwiftLint's
/// `nesting` rule. The rule is right: a reader should not unwrap three types
/// to find a coding key, and both models key on the same single field.
private enum ArgumentsKey: String, CodingKey { case arguments }

// MARK: - Codable

@Suite("JSONValue: Codable — plain JSON in, plain JSON out, and 1 is not 1.0")
struct JSONValueCodableTests {

    private func decoded(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private func encoded(_ value: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test("every case round-trips through JSONEncoder and JSONDecoder")
    func everyCaseRoundTrips() throws {
        let cases: [JSONValue] = [
            .null,
            .bool(true), .bool(false),
            .integer(0), .integer(1), .integer(-7), .integer(Int64.max),
            .double(1.5), .double(-0.25),
            .string(""), .string("hello"),
            .array([.integer(1), .string("two"), .null]),
            .object(["a": .bool(true), "b": .array([.double(0.5)])]),
        ]
        for value in cases {
            let text = try encoded(value)
            #expect(try decoded(text) == value, "round trip changed \(value) via \(text)")
        }
    }

    /// The reason `Int64` is tried before `Double`. JSON carries no
    /// integer/double distinction, so without the ordering every whole number
    /// would arrive as `.double` and a consumer switching on `.integer` would
    /// silently never match.
    @Test("a whole number decodes to .integer, not .double")
    func wholeNumbersAreIntegers() throws {
        #expect(try decoded("1") == .integer(1))
        #expect(try decoded("0") == .integer(0))
        #expect(try decoded("-42") == .integer(-42))
        #expect(try decoded("1.5") == .double(1.5))
    }

    /// The INVERSE of the Foundation trap `init(untyped:)` documents: there,
    /// every `NSNumber` bridges to `Bool` and `0`/`1` succeed, so the number
    /// has to be classified by `objCType`. Through `JSONDecoder` a boolean is
    /// its own JSON token, so trying `Bool` first is safe — and this test is
    /// what says so, in case anyone "aligns" the two initialisers.
    @Test("0 and 1 are integers, not booleans; true and false are booleans")
    func zeroAndOneAreNotBooleans() throws {
        #expect(try decoded("0") == .integer(0))
        #expect(try decoded("1") == .integer(1))
        #expect(try decoded("true") == .bool(true))
        #expect(try decoded("false") == .bool(false))
    }

    @Test("a number too large for Int64 becomes a double, as init(untyped:) also does")
    func oversizedNumbersBecomeDoubles() throws {
        let value = try decoded("9223372036854775808")  // Int64.max + 1
        guard case .double = value else {
            Issue.record("expected .double, got \(value)")
            return
        }
    }

    @Test("null decodes to .null and encodes back to null")
    func nullIsNull() throws {
        #expect(try decoded("null") == .null)
        #expect(try encoded(.null) == "null")
    }

    @Test("nested containers keep their shape")
    func nestedContainers() throws {
        let value = try decoded(#"{"a":[1,{"b":null}],"c":"x"}"#)
        #expect(value == .object([
            "a": .array([.integer(1), .object(["b": .null])]),
            "c": .string("x"),
        ]))
    }

    /// No wrapper, no discriminator: the encoded form is the JSON itself, so a
    /// `JSONValue` field inside a `Codable` model serialises as the sender's
    /// own JSON and not as an envelope the sender never wrote.
    @Test("encoding emits plain JSON, not a tagged envelope")
    func encodingIsPlainJSON() throws {
        #expect(try encoded(.string("x")) == #""x""#)
        #expect(try encoded(.integer(3)) == "3")
        #expect(try encoded(.bool(true)) == "true")
        #expect(try encoded(.array([.integer(1), .integer(2)])) == "[1,2]")
    }

    @Test("a JSONValue is usable as a stored property of a Codable model")
    func usableInsideAModel() throws {
        struct Call: Codable, Equatable {
            let name: String
            let arguments: JSONValue
        }
        let json = #"{"name":"write","arguments":{"path":"a.txt","lines":3}}"#
        let call = try JSONDecoder().decode(Call.self, from: Data(json.utf8))
        #expect(call.name == "write")
        #expect(call.arguments == .object(["path": .string("a.txt"), "lines": .integer(3)]))
        let again = try JSONDecoder().decode(Call.self, from: try JSONEncoder().encode(call))
        #expect(again == call)
    }
}

// MARK: - Text that contains JSON

@Suite("JSONValue(parsingJSON:) — a value, not only a document")
struct JSONValueParsingTests {

    @Test("an object and an array parse")
    func containersParse() throws {
        #expect(try JSONValue(parsingJSON: #"{"a":1}"#) == .object(["a": .integer(1)]))
        #expect(try JSONValue(parsingJSON: "[1,2]") == .array([.integer(1), .integer(2)]))
    }

    @Test("a bare scalar parses, because this type models a JSON value")
    func fragmentsParse() throws {
        #expect(try JSONValue(parsingJSON: "3") == .integer(3))
        #expect(try JSONValue(parsingJSON: "true") == .bool(true))
        #expect(try JSONValue(parsingJSON: "null") == .null)
        #expect(try JSONValue(parsingJSON: #""x""#) == .string("x"))
    }

    /// Empty input is the caller's decision, not this initialiser's: for a
    /// tool call `""` is a legitimate zero-argument call, for a config value
    /// it is a defect, and a default here would hide one of the two.
    @Test("empty, whitespace and malformed input throw rather than defaulting")
    func badInputThrows() {
        #expect(throws: (any Error).self) { try JSONValue(parsingJSON: "") }
        #expect(throws: (any Error).self) { try JSONValue(parsingJSON: "   ") }
        #expect(throws: (any Error).self) { try JSONValue(parsingJSON: "{oops") }
    }
}

// MARK: - Lenient: JSON, or a string containing JSON

@Suite("JSONValue lenient decode — the sender picks the shape")
struct JSONValueLenientTests {

    private struct Call: Decodable, Equatable {
        let arguments: JSONValue
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: ArgumentsKey.self)
            arguments = try c.decodeLenientJSON(forKey: .arguments)
        }
    }

    private func call(_ json: String) throws -> Call {
        try JSONDecoder().decode(Call.self, from: Data(json.utf8))
    }

    /// The whole point. An OpenAI-compatible provider sends `arguments` as a
    /// JSON STRING; others send the same field as an OBJECT. Both must land on
    /// one value, or every consumer needs a per-provider branch — which is the
    /// local primitive shikki#1961 had to add.
    @Test("a string-encoded object and a real object decode to the same value")
    func stringFormAndObjectFormAgree() throws {
        let asString = try call(#"{"arguments":"{\"path\":\"a.txt\",\"n\":3}"}"#)
        let asObject = try call(#"{"arguments":{"path":"a.txt","n":3}}"#)
        #expect(asString.arguments == .object(["path": .string("a.txt"), "n": .integer(3)]))
        #expect(asString == asObject)
    }

    @Test("a string-encoded array unwraps too")
    func stringEncodedArrayUnwraps() throws {
        #expect(try call(#"{"arguments":"[1,2]"}"#).arguments == .array([.integer(1), .integer(2)]))
    }

    /// A string that is not JSON is a VALUE, not an error — the sender meant
    /// text.
    @Test("a plain string stays a string")
    func plainStringStaysAString() throws {
        #expect(try call(#"{"arguments":"hello"}"#).arguments == .string("hello"))
        #expect(try call(#"{"arguments":""}"#).arguments == .string(""))
    }

    /// Containers only. `"\"x\""` and `"x"` would both unwrap to
    /// `.string("x")`, so unwrapping scalars would make two different payloads
    /// indistinguishable — and a sender who quoted a number would lose the
    /// fact that they sent a string.
    @Test("a string containing a bare scalar is NOT unwrapped")
    func quotedScalarsAreNotUnwrapped() throws {
        #expect(try call(#"{"arguments":"3"}"#).arguments == .string("3"))
        #expect(try call(#"{"arguments":"true"}"#).arguments == .string("true"))
        #expect(try call(#"{"arguments":"\"x\""}"#).arguments == .string(#""x""#))
    }

    @Test("the pure transform is the rule, and needs no Decoder to test")
    func pureTransform() {
        #expect(JSONValue(lenient: .string(#"{"a":1}"#)) == .object(["a": .integer(1)]))
        #expect(JSONValue(lenient: .string("nope")) == .string("nope"))
        #expect(JSONValue(lenient: .integer(5)) == .integer(5))
        #expect(JSONValue(lenient: .null) == .null)
        let already = JSONValue.object(["a": .integer(1)])
        #expect(JSONValue(lenient: already) == already)
    }

    private struct OptionalCall: Decodable {
        let arguments: JSONValue?
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: ArgumentsKey.self)
            arguments = try c.decodeLenientJSONIfPresent(forKey: .arguments)
        }
    }

    @Test("a missing key and an explicit null both decode to nil")
    func absentAndNullAreBothNil() throws {
        let missing = try JSONDecoder().decode(OptionalCall.self, from: Data("{}".utf8))
        let null = try JSONDecoder().decode(OptionalCall.self, from: Data(#"{"arguments":null}"#.utf8))
        #expect(missing.arguments == nil)
        #expect(null.arguments == nil)
        let present = try JSONDecoder().decode(
            OptionalCall.self, from: Data(#"{"arguments":"{\"a\":1}"}"#.utf8))
        #expect(present.arguments == .object(["a": .integer(1)]))
    }
}
