//
//  FlagValue.swift
//  CoreKit
//
//  Graduated from shikki-plugin-api's `ScopedFlagsCapability` (spec d3f8a1b2,
//  BR-RP-13): the resolved value of a feature flag, identical on the wire, so
//  the plugin-grant projection keeps its bytes and loses its private copy.
//

import Foundation

// MARK: - FlagValue

/// A resolved flag value: a closed set of four scalars.
///
/// Not `JSONValue`, and not a wildcard: an open value type would let a
/// resolver put a dictionary describing the flag — its tier, scope or
/// provenance — into a field typed "value". Four cases means a flag carries an
/// ANSWER and cannot carry a descriptor. Encodes as the bare JSON scalar, so
/// the wire shape is `{"telemetry.enabled": true}` and a non-Swift reader needs
/// no schema.
public enum FlagValue: Codable, Sendable, Equatable, Hashable {

    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    /// The scalar kind, for comparing a remote value against the local default
    /// it would replace.
    public enum Kind: String, Sendable, CaseIterable {
        case bool, int, double, string
    }

    public var kind: Kind {
        switch self {
        case .bool: .bool
        case .int: .int
        case .double: .double
        case .string: .string
        }
    }

    /// The value as a `Bool` when it is one, else `nil` — for a caller that
    /// wants to tell "on/off" from "not a boolean".
    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // `try?` is a TYPE PROBE across a closed set, not a swallowed failure:
        // when every probe misses, this initialiser THROWS below. The order is
        // load-bearing — JSON `1` decodes as both `Int` and `Double`, and `Int`
        // first keeps a whole number whole.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "FlagValue expects a bool, int, double or string — a flag carries a resolved value, never a descriptor")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

// MARK: - FlagSource

/// Where a resolved flag's value came from. Every resolution reports one, so
/// "why is this on" is answerable at the call site and `unavailable` is a
/// VALUE, never a placeholder string (spec 78957c3f, W3).
public enum FlagSource: String, Codable, Sendable, CaseIterable {
    /// The compiled default for this distribution.
    case localDefault
    /// A server-driven override applied on top of the local default.
    case remote
    /// A user override held locally (settings, a config file).
    case localOverride
    /// The resolver has no such flag.
    case unavailable
}

// MARK: - FlagResolution

/// One flag, resolved: its name, its value, and where the value came from.
/// `value` is `nil` exactly when `source` is ``FlagSource/unavailable``.
public struct FlagResolution: Codable, Sendable, Equatable {
    public let name: String
    public let value: FlagValue?
    public let source: FlagSource

    public init(name: String, value: FlagValue?, source: FlagSource) {
        self.name = name
        self.value = value
        self.source = source
    }

    /// The flag is not known to the resolver that was asked.
    public static func unavailable(_ name: String) -> FlagResolution {
        FlagResolution(name: name, value: nil, source: .unavailable)
    }

    /// `true` only for a resolved boolean `true`: unavailable, non-boolean and
    /// `false` all read as off, because a gate must treat them identically.
    public var isEnabled: Bool { value?.boolValue ?? false }
}
