# CoreKit

Foundation: DI, Coordinator, AppLog, Extensions.

## Installation

Add to your `Package.swift`:

```swift
.package(path: "../../packages/CoreKit")
```

No external dependencies.

## Documentation

- [Cache and its backings](docs/cache.md): two repositories over one backing protocol, and the S3 (Garage-compatible) backing end to end
- [The path layer](docs/paths.md): owners, registry, `PathLayer`, `TestRunRoot`
- [Environment keys and feature flags](docs/environment-and-flags.md)
- [Server-driven configuration](docs/config.md): `AppConfigService`, `ConfigEndpoint`

The code examples in these pages are compiled by `DocsExamplesTests`.

## License

AGPL-3.0-or-later — see [LICENSE](LICENSE).
