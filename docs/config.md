# Server-driven configuration

`AppConfig` is what only the server knows: kill switch, maintenance, version floor, remote flag overrides and free-form data, in the
snake_case record shape PocketBase serves. The same `Codable` decodes it from every source.

```swift
import CoreKit

func bootstrap(directory: URL) async {
    let query = AppConfigQuery(appId: "demo", environment: "prod")
    // The source: any ConfigEndpoint. This one reads a settings file held in a CacheRepository.
    let settings = CacheRepository<AppConfig>(
        "settings", invalidateTime: .never, baseDirectory: directory, envelope: .raw, naming: .bareId(ext: "json"))
    let service = AppConfigService(
        query: query,
        endpoint: RepositoryConfigEndpoint(repository: settings),
        cache: AsyncCacheRepository<AppConfig>("app-config", invalidateTime: .never, backing: InMemoryCacheBacking()))

    switch await service.bootstrap() {
    case .fetched, .usingCache: break
    case .unavailable: break                      // no configuration: run on local defaults
    }
    if let block = await service.block { _ = block.message }
}
```

## `ConfigEndpoint`: the injected source

```swift
public protocol ConfigEndpoint: Sendable {
    func fetchConfig(_ query: AppConfigQuery) async throws -> AppConfig
}
```

It throws `ConfigEndpointError.notFound` when the source holds nothing, and anything else unchanged; it never defaults.
Backings: `RepositoryConfigEndpoint` here (a settings file, any repository); the PocketBase endpoint in NetKit; the SQL endpoint in BackendKit.
`CoreKitTestSupport.ConfigEndpointConformance` is the suite each runs, so the same `AppConfig` comes out of every backing.

## `AppConfigService`

An actor. `bootstrap()` loads the cached configuration, asks the endpoint, caches the answer, and falls back to the cache when the endpoint
is down (`BootstrapResult.usingCache`) or to nothing when both are empty (`.unavailable`). Concurrent bootstraps join one fetch. A
configuration for another app (`appId` mismatch) is refused wherever it comes from. The cache is any `RepositoryProtocol<String, AppConfig>`,
so its backing and TTL are the host's choice. `currentConfig`, `block` and `isBlocked` are `async` reads.

`ConfigBackedFeatureFlags<Key>` merges the service's `featureFlags` into the local defaults on each resolution (see [flags](environment-and-flags.md)).
