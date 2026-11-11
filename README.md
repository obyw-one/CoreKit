# CoreKit

Foundation: DI, Coordinator, AppLog, Extensions.

## Installation

Add to your `Package.swift`:

```swift
.package(url: "https://github.com/obyw-one/CoreKit.git", from: "0.15.0"),
```

| Product | What it is | Platforms |
|---|---|---|
| `CoreKit` | DI, logging, JSON, cache over swappable backings, the path layer, env keys and flags, config | Apple + Linux |
| `CoreKitUI` | SwiftUI components, the coordinator, view extensions, network status | Apple |
| `CoreKitSecurity` | Keychain and auth persistence (replaces the archived SecurityKit) | Apple |
| `CoreKitTestSupport` | Test scratch roots, package paths, the backing conformance suites | Apple + Linux |

Dependencies: [swift-crypto](https://github.com/apple/swift-crypto) and [swift-log](https://github.com/apple/swift-log).

## Documentation

- [Cache and its backings](docs/cache.md): two repositories over one backing protocol, and the S3 (Garage-compatible) backing end to end
- [The path layer](docs/paths.md): owners, registry, `PathLayer`, `TestRunRoot`
- [Environment keys and feature flags](docs/environment-and-flags.md)
- [Server-driven configuration](docs/config.md): `AppConfigService`, `ConfigEndpoint`

The code examples in these pages are compiled by `DocsExamplesTests`.

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
