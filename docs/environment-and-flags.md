# Environment keys and feature flags

## Env keys

A module declares the variables it reads as one enum. `EnvKeyProviding` is an `EnvironmentKey` that may carry a per-case default.

```swift
import CoreKit

enum AgencyEnvKey: String, EnvKeyProviding {
    case dataRoot = "AGENCY_DATA_ROOT"
    case verbose = "AGENCY_VERBOSE"
    case port = "AGENCY_PORT"

    var defaultValue: String? {
        switch self {
        case .verbose: "false"
        case .dataRoot, .port: nil      // part of the configuration: no default
        }
    }
}

func configure() throws {
    let env = TypedEnvironment.current()        // the one sanctioned read of the process environment
    let root = try env.require(AgencyEnvKey.dataRoot)               // throws EnvKeyError.missing, no fallback
    let port = try env.require(AgencyEnvKey.port, as: Int.self)     // EnvKeyError.malformed names the key, never the value
    let verbose = env.resolve(AgencyEnvKey.verbose)                 // variable, then the key's default
    _ = (root, port, verbose)
}
```

- `require` stops on a missing or empty value; it never consults `defaultValue`, so a required key cannot be satisfied by a default.
- An empty variable counts as unset.
- `env.layered(over: settings)` layers the process environment over a settings snapshot; the empty value does not shadow a configured setting.
- A default is never a URL, endpoint or path: those are injected by the host.
- `EnvValue` holds the one definition of truthy (`1`, `true`, `yes`, `on`) used by `TypedEnvironment.flag`.

## Feature flags

A project declares its flags as an enum with local defaults per `Distribution` (`.debug`/`.release`); a flag can be pinned local-only.
Server overrides are merged on top.

```swift
import CoreKit

enum AppFlag: String, FeatureFlagKey {
    case featureX = "feature_x"
    case debugTab = "debug_tab"

    func localDefault(for distribution: Distribution) -> FlagValue {
        .bool(distribution == .debug)
    }

    var isRemoteControllable: Bool { self != .debugTab }     // pinned local-only
}

func flags() -> FeatureFlags<AppFlag> {
    FeatureFlags<AppFlag>(distribution: .release)
        .merged(with: RemoteFeatureFlags(["feature_x": .bool(true)]))
}
```

- `merged(with:)` applies a remote value only to a remotely controllable flag of the SAME scalar kind; a wrong kind is logged and ignored, an undeclared name is ignored.
- Every resolution reports its `FlagSource` (`localDefault`, `remote`, `localOverride`, `unavailable`); an unknown flag is `FlagResolution.unavailable`, a value, never a placeholder.
- `FeatureFlagResolving` is the DI slot (`DIAssemblyFeatureFlags(resolver:)`). `FeatureFlags` conforms; `ConfigBackedFeatureFlags` reads the overrides from the config service per resolution (see [config](config.md)).
- `flags.snapshot` is the name-to-value map a plugin grant is projected from.
