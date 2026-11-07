import CoreKit
import Foundation
import Testing

// MARK: - Fixtures

private enum AppFlag: String, FeatureFlagKey {
    case requirePaywall = "require_paywall"
    case featureX = "feature_x"
    case debugTab = "debug_tab"
    case maxItems = "max_items"

    func localDefault(for distribution: Distribution) -> FlagValue {
        switch self {
        case .requirePaywall: .bool(true)
        case .featureX: .bool(distribution == .debug)
        case .debugTab: .bool(distribution == .debug)
        case .maxItems: .int(10)
        }
    }

    /// The debug tab is pinned local-only.
    var isRemoteControllable: Bool { self != .debugTab }
}

private func remote(_ values: [String: FlagValue]) -> RemoteFeatureFlags { RemoteFeatureFlags(values) }

// MARK: - FeatureFlagsTests

@Suite("FeatureFlags — local defaults per distribution, remote overrides merged (BR-RP-13)")
struct FeatureFlagsTests {

    @Test("local defaults differ per distribution")
    func localDefaultsPerDistribution() {
        let debug = FeatureFlags<AppFlag>(distribution: .debug)
        let release = FeatureFlags<AppFlag>(distribution: .release)
        #expect(debug.isEnabled(.featureX))
        #expect(!release.isEnabled(.featureX))
        #expect(debug.isEnabled(.debugTab))
        #expect(!release.isEnabled(.debugTab))
        #expect(debug.isEnabled(.requirePaywall) && release.isEnabled(.requirePaywall))
        #expect(release[.maxItems] == .int(10))
    }

    @Test("every declared flag is present and reports a local default")
    func everyFlagResolved() {
        let flags = FeatureFlags<AppFlag>(distribution: .release)
        #expect(flags.snapshot.count == AppFlag.allCases.count)
        for key in AppFlag.allCases {
            #expect(flags.resolution(of: key).source == .localDefault)
            #expect(flags.resolution(of: key).name == key.rawValue)
        }
    }

    @Test("a remote override replaces a controllable flag and reports its source")
    func remoteOverrides() {
        let merged = FeatureFlags<AppFlag>(distribution: .release)
            .merged(with: remote(["feature_x": .bool(true), "max_items": .int(50)]))
        #expect(merged.isEnabled(.featureX))
        #expect(merged[.maxItems] == .int(50))
        #expect(merged.resolution(of: .featureX).source == .remote)
        #expect(merged.resolution(of: .requirePaywall).source == .localDefault, "untouched flags keep their source")
    }

    @Test("a flag pinned local-only is never remote-controlled")
    func pinnedLocalOnly() {
        let merged = FeatureFlags<AppFlag>(distribution: .release)
            .merged(with: remote(["debug_tab": .bool(true)]))
        #expect(!merged.isEnabled(.debugTab))
        #expect(merged.resolution(of: .debugTab).source == .localDefault)
    }

    @Test("a remote value of the wrong kind is not applied and not coerced")
    func kindMismatchKeepsLocal() {
        let merged = FeatureFlags<AppFlag>(distribution: .release)
            .merged(with: remote(["feature_x": .string("yes"), "max_items": .bool(true)]))
        #expect(!merged.isEnabled(.featureX))
        #expect(merged[.maxItems] == .int(10))
        #expect(merged.resolution(of: .featureX).source == .localDefault)
    }

    @Test("a remote flag this build does not declare is ignored")
    func unknownRemoteIgnored() {
        let base = FeatureFlags<AppFlag>(distribution: .release)
        let merged = base.merged(with: remote(["flag_from_the_future": .bool(true)]))
        #expect(merged == base)
    }

    @Test("no remote answer returns the flags unchanged: the app runs on its local defaults")
    func nilRemoteIsIdentity() {
        let base = FeatureFlags<AppFlag>(distribution: .debug)
        #expect(base.merged(with: nil) == base)
    }

    @Test("merging is a value operation: the original is untouched")
    func mergeDoesNotMutate() {
        let base = FeatureFlags<AppFlag>(distribution: .release)
        _ = base.merged(with: remote(["feature_x": .bool(true)]))
        #expect(!base.isEnabled(.featureX))
    }

    // MARK: FlagValue

    @Test("FlagValue encodes as the bare scalar and round-trips each kind")
    func flagValueWire() throws {
        let cases: [(FlagValue, String)] = [
            (.bool(true), "true"), (.int(7), "7"), (.double(1.5), "1.5"), (.string("a"), "\"a\""),
        ]
        for (value, json) in cases {
            let data = try JSONEncoder().encode([value])
            #expect(String(bytes: data, encoding: .utf8) == "[\(json)]")
            #expect(try JSONDecoder().decode([FlagValue].self, from: data) == [value])
        }
    }

    @Test("FlagValue refuses a descriptor: a flag carries an answer, never its own metadata")
    func flagValueRefusesObjects() {
        let object = Data("{\"tier\":\"enterprise\"}".utf8)
        let array = Data("[1]".utf8)
        let single = Data("null".utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(FlagValue.self, from: object) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(FlagValue.self, from: array) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(FlagValue.self, from: single) }
    }

    @Test("a whole number stays whole; a fraction is a double")
    func flagValueNumbers() throws {
        let decoded = try JSONDecoder().decode([FlagValue].self, from: Data("[1, 1.5]".utf8))
        #expect(decoded == [.int(1), .double(1.5)])
    }

    @Test("FlagValue.kind and boolValue")
    func flagValueKinds() {
        #expect(FlagValue.bool(true).kind == .bool)
        #expect(FlagValue.int(1).kind == .int)
        #expect(FlagValue.double(1).kind == .double)
        #expect(FlagValue.string("x").kind == .string)
        #expect(FlagValue.bool(false).boolValue == false)
        #expect(FlagValue.int(1).boolValue == nil)
    }

    @Test("RemoteFeatureFlags decodes the server's bare object")
    func remoteDecodes() throws {
        let payload = Data("{\"feature_x\":true,\"max_items\":5,\"theme\":\"dark\"}".utf8)
        let decoded = try JSONDecoder().decode(RemoteFeatureFlags.self, from: payload)
        #expect(decoded.values == ["feature_x": .bool(true), "max_items": .int(5), "theme": .string("dark")])
        let reencoded = try JSONEncoder().encode(decoded)
        #expect(try JSONDecoder().decode(RemoteFeatureFlags.self, from: reencoded) == decoded)
    }

    // MARK: Resolver slot

    @Test("FeatureFlags is a resolver: a declared flag resolves, an unknown one is unavailable as a VALUE")
    func resolverUnknownIsAValue() async {
        let resolver: any FeatureFlagResolving = FeatureFlags<AppFlag>(distribution: .debug)
        let known = await resolver.resolve("feature_x")
        #expect(known.value == .bool(true))
        #expect(known.isEnabled)
        let unknown = await resolver.resolve("nope")
        #expect(unknown == .unavailable("nope"))
        #expect(unknown.value == nil)
        #expect(!unknown.isEnabled)
        #expect(unknown.source == .unavailable)
    }

    @Test("a non-boolean flag reads as off through isEnabled")
    func nonBooleanIsOff() async {
        let resolution = await FeatureFlags<AppFlag>(distribution: .debug).resolve("max_items")
        #expect(!resolution.isEnabled)
        #expect(resolution.value == .int(10))
    }

    @Test("the static resolver serves fixed resolutions and reports the rest unavailable")
    func staticResolver() async {
        let resolver = StaticFeatureFlagResolver(values: ["a": .bool(true)])
        #expect(await resolver.resolve("a").isEnabled)
        #expect(await resolver.resolve("b") == .unavailable("b"))
        let override = StaticFeatureFlagResolver([FlagResolution(name: "a", value: .bool(false), source: .localOverride)])
        #expect(await override.resolve("a").source == .localOverride)
    }

    @Test("the DI slot hands every component the one resolver")
    func diSlot() async throws {
        let container = Container(name: "flags")
        DIAssemblyFeatureFlags(resolver: FeatureFlags<AppFlag>(distribution: .release))
            .assemble(container: container, environment: .production)
        let resolver = try container.resolve((any FeatureFlagResolving).self)
        #expect(await resolver.resolve("require_paywall").isEnabled)
    }

    @Test("a plugin grant can be projected from the snapshot")
    func snapshotIsTheGrantInput() {
        let snapshot = FeatureFlags<AppFlag>(distribution: .release).snapshot
        #expect(snapshot["feature_x"] == .bool(false))
        #expect(snapshot["require_paywall"] == .bool(true))
        #expect(Set(snapshot.keys) == Set(AppFlag.allCases.map(\.rawValue)))
    }

    @Test("Distribution.current follows the compiler's DEBUG condition")
    func distributionCurrent() {
        #if DEBUG
            #expect(Distribution.current == .debug)
            #expect(Distribution.isDebugBuild)
        #else
            #expect(Distribution.current == .release)
            #expect(!Distribution.isDebugBuild)
        #endif
        #expect(Distribution.allCases == [.debug, .release])
    }
}
