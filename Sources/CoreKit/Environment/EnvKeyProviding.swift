//
//  EnvKeyProviding.swift
//  CoreKit
//
//  Graduated from shikki-plugin-api (spec d3f8a1b2, BR-RP-12). The PROTOCOL is
//  fleet-wide and lives with the other resolution primitives; each project's
//  CONCRETE key enum (shikki's `PluginAPIEnvKey`, a kit's `PostgresEnvKey`)
//  stays in that project — the identical two-layer split as the path layer.
//

import Foundation

// MARK: - EnvKeyProviding

/// An ``EnvironmentKey`` that may declare a compiled default for its variable.
///
/// `EnvironmentKey` is layer 1: the NAMES a module reads, enumerable for a
/// doctor, never a raw literal at a call site. `EnvKeyProviding` is the layer
/// above it that carries a per-case ``defaultValue`` for the keys that have a
/// sensible one — so there is still ONE place a default is spelled (the key's
/// own declaration) and one resolver that applies it
/// (``TypedEnvironment/resolve(_:)``).
///
/// ```swift
/// public enum AgencyEnvKey: String, EnvKeyProviding {
///     case dataRoot = "SHI_AGENCY_DATA_ROOT"
///     case verbose  = "SHI_AGENCY_VERBOSE"
///
///     public var defaultValue: String? {
///         switch self {
///         case .dataRoot: nil        // must be set — a missing one is a misconfiguration
///         case .verbose:  "false"
///         }
///     }
/// }
/// ```
///
/// A default is opt-in per case, and NEVER a URL, endpoint or path: those are
/// injected by the host, not defaulted by a key. A key without a default is
/// read with ``TypedEnvironment/require(_:)``, which stops on a missing value
/// instead of inventing one.
public protocol EnvKeyProviding: EnvironmentKey {

    /// The value ``TypedEnvironment/resolve(_:)`` falls back to when the
    /// variable is unset or empty. `nil` (the default) means "no default":
    /// unset stays distinguishable from any value.
    var defaultValue: String? { get }
}

extension EnvKeyProviding {
    public var defaultValue: String? { nil }
}

// MARK: - EnvValue

/// Normalisation shared by every env-derived value in the fleet — the ONE
/// definition of "truthy" and of "blank".
///
/// Two accessors that disagree about one variable is the bug this exists to
/// prevent (`FOO=on` true through one, false through the other); both
/// ``TypedEnvironment`` and any consumer's typed accessor read it from here.
public enum EnvValue {

    /// The fleet's truthy token set (compared case-insensitively).
    public static let truthyTokens: Set<String> = ["1", "true", "yes", "on"]

    /// Truthiness for a raw value, whitespace-trimmed and case-insensitive.
    public static func isTruthy(_ raw: String?) -> Bool {
        guard let value = normalized(raw) else { return false }
        return truthyTokens.contains(value.lowercased())
    }

    /// Trims whitespace and treats empty or whitespace-only as absent.
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - EnvKeyError

/// A configuration the process cannot start on. Names the KEY, never the
/// value: an environment value may be a token, and an error that echoes it
/// lands in a log.
public enum EnvKeyError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// The variable is unset or empty and has no value to stop that.
    case missing(name: String)
    /// The variable is set but is not a `expected`.
    case malformed(name: String, expected: String)

    public var description: String {
        switch self {
        case .missing(let name):
            "Environment: \(name) is missing or empty — it is part of the configuration and has no default"
        case .malformed(let name, let expected):
            "Environment: \(name) is set but is not \(expected)"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - TypedEnvironment resolution

extension TypedEnvironment {

    /// The variable, else the key's compiled ``EnvKeyProviding/defaultValue``,
    /// else `nil`. Env wins; an empty variable counts as unset.
    public func resolve(_ key: some EnvKeyProviding) -> String? {
        self[key] ?? key.defaultValue
    }

    /// The variable, or a thrown ``EnvKeyError/missing(name:)`` — the NO-FALLBACK
    /// reader (BR-RP-12). A missing or empty value is a misconfiguration that
    /// stops before the first request, never a silent default. Reads the
    /// variable only: a key's ``EnvKeyProviding/defaultValue`` is deliberately
    /// not consulted, so a required key cannot be quietly satisfied by one.
    public func require(_ key: some EnvironmentKey) throws(EnvKeyError) -> String {
        guard let value = self[key] else { throw .missing(name: key.rawValue) }
        return value
    }

    /// ``require(_:)`` parsed as `Value` (`Int`, `Bool`, `URL`-like
    /// `LosslessStringConvertible` types). A value that does not parse throws
    /// ``EnvKeyError/malformed(name:expected:)`` naming the type, not the value.
    public func require<Value: LosslessStringConvertible>(
        _ key: some EnvironmentKey, as _: Value.Type
    ) throws(EnvKeyError) -> Value {
        let raw = try require(key)
        guard let value = Value(raw) else {
            throw .malformed(name: key.rawValue, expected: String(describing: Value.self))
        }
        return value
    }
}
