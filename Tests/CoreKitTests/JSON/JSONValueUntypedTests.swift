import CoreKit
import Foundation
import Testing

@Suite("JSONValue(untyped:) — a number is classified by what it is, not by what it casts to")
struct JSONValueUntypedTests {

    /// Parses `json` with `JSONSerialization` (the producer this initialiser
    /// exists for) and converts the one top-level array element.
    private func parsed(_ literal: String) throws -> JSONValue {
        let tree = try JSONSerialization.jsonObject(with: Data("[\(literal)]".utf8))
        let array = try #require(tree as? [Any])
        return JSONValue(untyped: try #require(array.first))
    }

    @Test("JSON true and false stay booleans")
    func booleans() throws {
        #expect(try parsed("true") == .bool(true))
        #expect(try parsed("false") == .bool(false))
    }

    @Test("JSON 0, 1, 2 and -1 stay integers — 0 and 1 are not booleans", arguments: [
        ("0", Int64(0)), ("1", 1), ("2", 2), ("-1", -1), ("100", 100),
    ])
    func integers(literal: String, expected: Int64) throws {
        #expect(try parsed(literal) == .integer(expected))
    }

    @Test("fractions, 1.0 and exponents stay doubles", arguments: [
        ("1.0", 1.0), ("0.0", 0.0), ("1.5", 1.5), ("-2.25", -2.25), ("1e30", 1e30),
    ])
    func doubles(literal: String, expected: Double) throws {
        #expect(try parsed(literal) == .double(expected))
    }

    @Test("the largest 64-bit integer is an integer; one past it is a double")
    func integerRange() throws {
        #expect(try parsed("9223372036854775807") == .integer(Int64.max))
        #expect(try parsed("18446744073709551615") == .double(Double(UInt64.max)))
    }

    @Test("a mixed document keeps every kind apart")
    func mixedDocument() throws {
        let tree = try JSONSerialization.jsonObject(
            with: Data(#"{"flag":true,"off":false,"zero":0,"one":1,"ratio":1.0,"name":"x","none":null,"list":[1,true,2.5]}"#.utf8))
        #expect(JSONValue(untyped: tree) == .object([
            "flag": .bool(true), "off": .bool(false), "zero": .integer(0), "one": .integer(1),
            "ratio": .double(1.0), "name": .string("x"), "none": .null,
            "list": .array([.integer(1), .bool(true), .double(2.5)]),
        ]))
    }

    @Test("native Swift values are classified by their own type")
    func nativeValues() {
        #expect(JSONValue(untyped: true) == .bool(true))
        #expect(JSONValue(untyped: 1) == .integer(1))
        #expect(JSONValue(untyped: 0) == .integer(0))
        #expect(JSONValue(untyped: Int64(7)) == .integer(7))
        #expect(JSONValue(untyped: 1.0) == .double(1.0))
        #expect(JSONValue(untyped: "s") == .string("s"))
        #expect(JSONValue(untyped: Int8(1)) == .integer(1), "an Int8 is a number, not a boolean")
        #expect(JSONValue(untyped: UInt8(1)) == .integer(1))
        #expect(JSONValue(untyped: Float(2.5)) == .double(2.5))
    }

    @Test("NSNumber values built by hand are classified by their type")
    func nsNumbers() {
        #expect(JSONValue(untyped: NSNumber(value: 1)) == .integer(1))
        #expect(JSONValue(untyped: NSNumber(value: 0)) == .integer(0))
        #expect(JSONValue(untyped: NSNumber(value: 1.5)) == .double(1.5))
        #expect(JSONValue(untyped: NSNumber(value: Int64.max)) == .integer(Int64.max))
    }

    @Test("things the enum does not model become null")
    func unmodelled() {
        #expect(JSONValue(untyped: NSNull()) == .null)
        #expect(JSONValue(untyped: Date()) == .null)
    }

    @Test("untyped round-trips back through JSONSerialization with every kind intact")
    func roundTrip() throws {
        let original = JSONValue.object([
            "flag": .bool(true), "zero": .integer(0), "one": .integer(1), "ratio": .double(0.5), "list": .array([.bool(false), .integer(2)]),
        ])
        let data = try JSONSerialization.data(withJSONObject: original.untyped)
        let reparsed = JSONValue(untyped: try JSONSerialization.jsonObject(with: data))
        #expect(reparsed == original)
    }
}
