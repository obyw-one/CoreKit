import Foundation

// MARK: - EnvironmentKey

/// A declared environment variable name. Every kit and app lists the
/// variables it reads as one `String`-backed enum conforming to this
/// protocol (BackendKit's `PostgresEnvKey`, a test target's live-test
/// switch, shikki's `ShikkiEnvKey` once spec 9d2f6b8e lands) so that:
///
/// - the set of names a module reads is enumerable (`allCases`) for a
///   doctor / env-surface audit,
/// - no call site spells a raw `"NAME"` literal into a dictionary lookup,
/// - the ONE place that touches `ProcessInfo.processInfo.environment` is
///   `TypedEnvironment.current()` below — a consumer's ratchet can ban the
///   raw read everywhere else (BackendKit #2 review: "never manage it like
///   this with a raw call of swift api").
public protocol EnvironmentKey: RawRepresentable<String>, CaseIterable, Sendable, Hashable {}

// MARK: - TypedEnvironment

/// An immutable snapshot of environment variables read only through
/// `EnvironmentKey` values. Construct one from the process (`current()`)
/// at the edge, or from a literal dictionary in tests, and pass it down —
/// resolvers take a `TypedEnvironment`, never read the process themselves.
public struct TypedEnvironment: Sendable, Equatable {
    private let storage: [String: String]

    /// A snapshot over an explicit dictionary — tests and spawners that
    /// assemble a child's environment use this.
    public init(_ variables: [String: String]) {
        storage = variables
    }

    /// The process environment as of now. This is the single sanctioned
    /// read of `ProcessInfo.processInfo.environment` in the fleet; a fresh
    /// call re-reads so a `setenv` before it (tests only) is observed.
    public static func current() -> TypedEnvironment {
        TypedEnvironment(ProcessInfo.processInfo.environment)
    }

    /// The empty environment — for resolvers that must fall back to their
    /// defaults with nothing set.
    public static let empty = TypedEnvironment([:])

    /// The value for `key`, or `nil` when unset OR set to the empty string.
    /// Folding empty into `nil` matches libpq / POSIX tooling, where
    /// `FOO=` means "not configured", and removes an `isEmpty` check from
    /// every caller.
    public subscript(_ key: some EnvironmentKey) -> String? {
        value(named: key.rawValue)
    }

    /// The value for `prefix + key.rawValue` — the shape a kit uses when a
    /// consumer scopes the kit's keys (`SHIKKI_DB_` + `HOST`). The prefix is
    /// data the consumer chose; the suffix stays a declared key.
    public subscript(_ key: some EnvironmentKey, prefix prefix: String) -> String? {
        value(named: prefix + key.rawValue)
    }

    /// `true` for the conventional truthy spellings (`1`, `true`, `yes`,
    /// `on`, case-insensitive); `false` when unset or anything else.
    public func flag(_ key: some EnvironmentKey) -> Bool {
        guard let raw = self[key] else { return false }
        return Self.truthy.contains(raw.lowercased())
    }

    /// Which of `Key.allCases` are set in this snapshot — the audit surface
    /// a doctor check prints.
    public func presentKeys<Key: EnvironmentKey>(of _: Key.Type) -> [Key] {
        Key.allCases.filter { self[$0] != nil }
    }

    /// Number of variables in the snapshot (set and non-empty or not).
    public var count: Int {
        storage.count
    }

    // MARK: - Private

    private static let truthy: Set<String> = ["1", "true", "yes", "on"]

    private func value(named name: String) -> String? {
        guard let raw = storage[name], !raw.isEmpty else { return nil }
        return raw
    }
}
