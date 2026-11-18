import Foundation

// MARK: - JSONValue: Codable
//
// `JSONValue` has been `Sendable + Equatable` with `init(untyped:)` / `untyped`
// since it was extracted from shikki's `PlanRepository` (#1505). That pair
// speaks `JSONSerialization`, which is the right boundary for a Foundation
// caller and the wrong one for a `Decodable` model: a field whose shape is the
// SENDER'S choice — "whatever JSON they put here" — could not be a stored
// property of a `Codable` struct without that model owning a
// `JSONSerialization` round-trip itself.
//
// shikki#1961 hit exactly that and had to declare a LOCAL primitive
// (`AgentToolArguments` in `ShiKit/CodeGen/AgentToolSurface.swift`) to decode
// an OpenAI tool call's `arguments`. Two vocabularies for one concept is the
// defect this conformance removes; the instruction was "add one primitive to
// CoreKit", not a second type.
//
// This is an EXTENSION, in its own file, so `JSONValue.swift` keeps every
// existing declaration byte-for-byte: `init(untyped:)` and `untyped` remain
// the Foundation boundary and are untouched.

extension JSONValue: Codable {

    /// Decode any JSON value.
    ///
    /// The case order mirrors ``init(untyped:)``'s rules rather than inventing
    /// new ones:
    ///
    /// - `null` first: `decodeNil()` is the only question with a yes/no answer.
    /// - `Bool` before the numbers. In JSON a boolean is its own token, so
    ///   `JSONDecoder` refuses `0` as a `Bool` and there is nothing to
    ///   disambiguate — unlike the Foundation path, where every `NSNumber`
    ///   bridges to `Bool` and `0`/`1` succeed. That asymmetry is why
    ///   ``init(untyped:)`` must inspect `objCType` and this initialiser must
    ///   not; the note is here so nobody "aligns" the two.
    /// - `Int64` before `Double`, so `1` is `.integer(1)` and not
    ///   `.double(1.0)`. A number too large for `Int64` falls through to
    ///   `.double`, the same rule `fromInteger(_:)` applies.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
            return
        }
        if let double = try? container.decode(Double.self) {
            self = .double(double)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
            return
        }
        if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "not a JSON value: expected null, bool, number, string, array or object")
    }

    /// Encode as plain JSON — no wrapper, no discriminator. A `JSONValue`
    /// round-trips to the bytes it came from, modulo key order and the
    /// integer/double distinction JSON itself does not carry.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .integer(let integer): try container.encode(integer)
        case .double(let double): try container.encode(double)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }
}

// MARK: - Text that contains JSON

extension JSONValue {

    /// Parse text that CONTAINS JSON — the shape a model's `arguments` field
    /// arrives in, and the shape any TOML/env/CLI value arrives in when
    /// someone has put a JSON document inside a string.
    ///
    /// `.fragmentsAllowed`, so a bare `3`, `"x"`, `true` or `null` parses: this
    /// type models a JSON *value*, not only a document.
    ///
    /// Empty or whitespace-only input is NOT silently an empty object. The
    /// caller decides what nothing means, because for a tool call `""` is a
    /// legitimate zero-argument call while for a config value it is a defect,
    /// and both need to tell them apart. `JSONSerialization`'s own error is
    /// thrown unchanged — it names the byte offset, and wrapping it would lose
    /// that.
    public init(parsingJSON text: String) throws {
        // `Data(text.utf8)` and not `text.data(using:)`: a Swift `String` is
        // always valid Unicode, so the optional form can never be nil and an
        // `else` branch for it would be unreachable code pretending to be a
        // guard.
        let any = try JSONSerialization.jsonObject(
            with: Data(text.utf8), options: [.fragmentsAllowed])
        self = JSONValue(untyped: any)
    }

    /// Unwrap one level of "a document inside a string".
    ///
    /// A pure transform, so the rule is testable without a `Decoder` and the
    /// decoding initialiser below has no logic of its own.
    ///
    /// A `.string` whose text parses as a JSON **container** becomes that
    /// container; everything else is returned unchanged. Containers only,
    /// deliberately: `"\"x\""` and `"x"` would both yield `.string("x")`, so
    /// unwrapping a scalar would make two different payloads
    /// indistinguishable. A container is the one case where the sender can
    /// have meant "here is a document in a string", and a `.string` that is
    /// not JSON at all stays a `.string` — it is a value, not an error.
    public init(lenient value: JSONValue) {
        guard case .string(let text) = value,
            let nested = try? JSONValue(parsingJSON: text)
        else {
            self = value
            return
        }
        switch nested {
        case .array, .object: self = nested
        default: self = value
        }
    }

    /// Decode a value that may arrive EITHER as JSON or as a string containing
    /// JSON, which is what "JSON of the sender's choosing" means in practice.
    ///
    /// OpenAI-compatible tool calls send `arguments` as a JSON **string**;
    /// other providers send the same field as an **object**. A model that
    /// declares the field as `JSONValue` and decodes it leniently accepts both
    /// without a per-provider branch.
    public init(lenientFrom decoder: any Decoder) throws {
        self = JSONValue(lenient: try JSONValue(from: decoder))
    }
}

// MARK: - Keyed convenience

extension KeyedDecodingContainer {

    /// ``JSONValue/init(lenient:)`` at a key: JSON, or a string containing
    /// JSON, whichever the sender chose.
    public func decodeLenientJSON(forKey key: Key) throws -> JSONValue {
        JSONValue(lenient: try decode(JSONValue.self, forKey: key))
    }

    /// The same, absent-tolerant. A missing key and an explicit `null` both
    /// return `nil`, because a sender omitting the field and a sender saying
    /// "no value" mean the same thing to a caller that has no schema for it.
    public func decodeLenientJSONIfPresent(forKey key: Key) throws -> JSONValue? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeLenientJSON(forKey: key)
    }
}
