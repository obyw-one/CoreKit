# Changelog

## Unreleased: the fleet resource layer (spec d3f8a1b2)

### Added
- **Paths**: `VirtualPathOwning`, `VirtualPathRegistry`, `PathResolving` / `PathLayer` over an injected root, `PathSegment`, `VirtualPath`, `PathContainment`, `ResourceAddress` (bucket, node id, key), `TestRunRoot`, `OwnedResourceStore`.
- **Env and flags**: `EnvKeyProviding`, `TypedEnvironment.require` / `resolve` / `layered(over:)`, `FeatureFlagKey`, `FeatureFlags`, `FeatureFlagResolving`.
- **Cache**: `CacheBacking`, `LocalFolderCacheBacking`, `InMemoryCacheBacking`, `AsyncCacheRepository`, `ObjectStoreCacheBacking`, `S3ObjectStoreClient`, and the conformance suites in `CoreKitTestSupport`.
- **Config**: `AppConfig`, `ConfigEndpoint`, `AppConfigService`, `ConfigBackedFeatureFlags`.
- `CacheDirectory` and `CacheLocationError`: the cache directory as a resource the path layer owns.

### Deprecated: `CacheRepository` with no directory
`CacheRepository(_:invalidateTime:baseDirectory: URL? = nil, ...)` used to store in the app's documents folder when `baseDirectory` was left out or `nil`. A default nobody chose is gone:

| You wrote | What happens now |
|---|---|
| `baseDirectory: someURL` (a non-optional `URL`) | Unchanged, no warning. |
| no `baseDirectory`, or `baseDirectory: nil`, or a `URL?` | **Deprecation warning.** The directory is resolved through the `PathResolving` registered in DI: its root, then the `CacheDirectory` node. |
| ... and no `PathResolving` is registered | Every operation (`get`, `save`, `delete`, `list`) **throws `CacheLocationError.noPathLayerRegistered`**; `exists` logs the cause and returns `false`. Nothing is written anywhere. |

**Migration, pick one:**
1. Pass the directory: `CacheRepository<M>("name", baseDirectory: dir)` where `dir` is a `URL` your path layer resolved, or the documents folder you were already using (`FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)`), if you want the old location on purpose.
2. Pass the layer: `CacheRepository<M>("name", in: paths)`.
3. Rely on DI: register `DIAssemblyResourcePaths(layer:)` with a `PathLayer` whose registry contains `CacheDirectory.self`, and keep the nil form (still warns).

Files written by the old default live in the documents folder as `<name>-<id>.cache`; with option 1 they are found where they were.

### Fixed
- `JSONValue(untyped:)`: the integers `0` and `1` came back as booleans, because `as Bool` succeeds on any bridged `NSNumber`. A number is now classified by its type, on macOS and on Linux.

### Changed (concurrency)
- `AppConfigService`, `MockAppConfigService`, `InMemoryCacheBacking`, `InMemoryResourceStore`, `MockCapacityProber` and `FakeDrainClock` are actors; none is `@unchecked Sendable`.
- `AppConfigServiceProtocol.currentConfig` / `.block` / `.isBlocked` are `async`; `ResourceStoring` requirements are `async`; `DrainClock.now()` and `DeviceCapacityProbing.probe()` are `async` (a conformer with a synchronous method still satisfies them; only callers through the protocol `await`). `FakeDrainClock.sleeps` and `MockCapacityProber.probeCount` are read with `await`.
- `InMemoryCacheBacking` conforms to `CacheBacking` only: use it through `AsyncCacheRepository`. A synchronous cache without a persistent footprint uses `LocalFolderCacheBacking` on a scratch folder.
- Kept, documented: `Container`, `DI` (lock-guarded, synchronous `resolve`), `AppLog.subsystem` and `AppIdentity.bundleId` (write-once launch configuration). See the notes on those types and the pull request.
