//
//  FeatureFlags.swift
//  CoreKit
//
//  Promoted from WabiSabi's `FeatureFlags` / `RemoteFeatureFlags` (spec
//  d3f8a1b2, BR-RP-13): LOCAL defaults per `Distribution`, `.merged(with:)`
//  applying server overrides, and some flags pinned local-only. What WabiSabi
//  spelled as four hard-coded fields is here a project's own key enum — the
//  PATTERN is promoted and no concrete flag is baked in.
//

import Foundation

// MARK: - FeatureFlagKey

/// A project's declared feature flags, as one enum.
///
/// ```swift
/// enum AppFlag: String, FeatureFlagKey {
///     case requirePaywall = "require_paywall"
///     case featureX       = "feature_x"
///     case debugTab       = "debug_tab"
///
///     func localDefault(for distribution: Distribution) -> FlagValue {
///         switch self {
///         case .requirePaywall: .bool(true)
///         case .featureX:       .bool(distribution == .debug)
///         case .debugTab:       .bool(distribution == .debug)
///         }
///     }
///
///     var isRemoteControllable: Bool { self != .debugTab }   // pinned local-only
/// }
/// ```
///
/// The enum is the SSoT for the flag set: enumerable (`allCases`) for a doctor,
/// exhaustively switched, and the raw value is the name on the wire.
public protocol FeatureFlagKey: RawRepresentable<String>, CaseIterable, Sendable, Hashable {

    /// The local answer for `distribution`. Every flag has one: the app runs on
    /// local defaults when the server has not answered, inventing nothing.
    func localDefault(for distribution: Distribution) -> FlagValue

    /// `false` pins the flag local-only: a remote override for it is ignored
    /// (a debug tab is never remote-controlled). `true` by default.
    var isRemoteControllable: Bool { get }
}

extension FeatureFlagKey {
    public var isRemoteControllable: Bool { true }
}

// MARK: - RemoteFeatureFlags

/// Server-driven flag overrides: a flat object of flag name to scalar.
///
/// Decodes the bare JSON object the server sends (`{"feature_x": true}`), so a
/// backing needs no flag-specific model. Names that are not in the receiving
/// key enum are ignored by ``FeatureFlags/merged(with:)``.
public struct RemoteFeatureFlags: Codable, Sendable, Equatable {

    public let values: [String: FlagValue]

    public init(_ values: [String: FlagValue] = [:]) {
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: FlagValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

// MARK: - FeatureFlags

/// A project's resolved flags: local defaults for a distribution, optionally
/// merged with server overrides. A value type — copy it into any task.
public struct FeatureFlags<Key: FeatureFlagKey>: Sendable, Equatable {

    private struct Entry: Sendable, Equatable {
        let value: FlagValue
        let source: FlagSource
    }

    public let distribution: Distribution
    private let entries: [Key: Entry]

    /// The local defaults for `distribution`.
    public init(distribution: Distribution) {
        self.distribution = distribution
        entries = Dictionary(
            uniqueKeysWithValues: Key.allCases.map {
                ($0, Entry(value: $0.localDefault(for: distribution), source: .localDefault))
            })
    }

    private init(distribution: Distribution, entries: [Key: Entry]) {
        self.distribution = distribution
        self.entries = entries
    }

    // MARK: Reading

    /// The resolved value of `key`.
    public subscript(_ key: Key) -> FlagValue { entry(of: key).value }

    /// `true` only for a flag that resolved to boolean `true`.
    public func isEnabled(_ key: Key) -> Bool { self[key].boolValue ?? false }

    /// `key`, with the source of its value.
    public func resolution(of key: Key) -> FlagResolution {
        let entry = entry(of: key)
        return FlagResolution(name: key.rawValue, value: entry.value, source: entry.source)
    }

    /// Every flag as wire name to value — the input of a plugin-grant
    /// projection (`ScopedFlagsCapability.granting(_:from:)`).
    public var snapshot: [String: FlagValue] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value.value) })
    }

    // MARK: Merging

    /// These flags with `remote` overrides applied.
    ///
    /// - A flag pinned local-only (``FeatureFlagKey/isRemoteControllable`` is
    ///   `false`) is never changed.
    /// - A remote value of a different scalar kind than the local default is
    ///   NOT applied and not coerced: the local value stays and the mismatch is
    ///   logged with its cause, because a server that sends a string for a
    ///   boolean has a bug the client must not paper over.
    /// - A remote name that is not a declared flag is ignored (the server may
    ///   know flags this build does not) and logged once.
    ///
    /// `nil` returns the flags unchanged: the server has not answered.
    public func merged(with remote: RemoteFeatureFlags?) -> FeatureFlags {
        guard let remote else { return self }
        var next = entries
        var unknown: [String] = []
        for (name, value) in remote.values.sorted(by: { $0.key < $1.key }) {
            guard let key = Key(rawValue: name) else {
                unknown.append(name)
                continue
            }
            guard key.isRemoteControllable else { continue }
            let local = entry(of: key).value
            guard local.kind == value.kind else {
                AppLog.config.warning(
                    "Remote flag \(name) ignored: server sent \(value.kind.rawValue), the local default is \(local.kind.rawValue)")
                continue
            }
            next[key] = Entry(value: value, source: .remote)
        }
        if !unknown.isEmpty {
            AppLog.config.debug("Remote flags not declared by this build, ignored: \(unknown.joined(separator: ", "))")
        }
        return FeatureFlags(distribution: distribution, entries: next)
    }

    // MARK: Private

    private func entry(of key: Key) -> Entry {
        // Every case is present by construction (`init(distribution:)` walks
        // `allCases`), so the fallback is unreachable; it recomputes the local
        // default rather than force-unwrapping.
        entries[key] ?? Entry(value: key.localDefault(for: distribution), source: .localDefault)
    }
}

// MARK: - FeatureFlagResolving

/// The DI slot a component asks for a flag by name (BR-RP-13).
///
/// Async so a resolver whose state is an actor (shikki's flag registry, with
/// its tier gate) can conform; a synchronous value type satisfies the
/// requirement unchanged. Never throws: an unknown flag is a VALUE
/// (``FlagResolution/unavailable(_:)``), not an error and not a placeholder.
public protocol FeatureFlagResolving: Sendable {
    func resolve(_ flag: String) async -> FlagResolution
}

extension FeatureFlags: FeatureFlagResolving {
    public func resolve(_ flag: String) -> FlagResolution {
        guard let key = Key(rawValue: flag) else { return .unavailable(flag) }
        return resolution(of: key)
    }
}

/// A fixed set of resolutions — the test double for ``FeatureFlagResolving``
/// and the resolver for a host that computed its flags up front.
public struct StaticFeatureFlagResolver: FeatureFlagResolving {

    private let resolutions: [String: FlagResolution]

    public init(_ resolutions: [FlagResolution]) {
        self.resolutions = Dictionary(resolutions.map { ($0.name, $0) }) { _, latest in latest }
    }

    /// Every flag in `values`, as a local default.
    public init(values: [String: FlagValue]) {
        self.init(values.map { FlagResolution(name: $0.key, value: $0.value, source: .localDefault) })
    }

    public func resolve(_ flag: String) -> FlagResolution {
        resolutions[flag] ?? .unavailable(flag)
    }
}

// MARK: - DIAssemblyFeatureFlags

/// Registers a ``FeatureFlagResolving`` on the container. The host builds the
/// resolver (local defaults, a config-backed one, a registry) and this slot
/// hands it to every component under one protocol.
public struct DIAssemblyFeatureFlags: DIAssembly {

    public let resolver: any FeatureFlagResolving

    public init(resolver: any FeatureFlagResolving) {
        self.resolver = resolver
    }

    public func assemble(container: Container, environment: DIEnvironment) {
        let resolver = resolver
        do {
            try container.register((any FeatureFlagResolving).self, scope: .cached) { _ in resolver }
        } catch {
            fatalError("DIAssemblyFeatureFlags: the container refused `FeatureFlagResolving` — \(error). Is the assembly listed twice?")
        }
    }
}
