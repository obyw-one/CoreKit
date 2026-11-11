# Cache and its backings

A cache here is **two repositories over one backing protocol**, not six cache systems.

| Type | What it is | Why it exists |
|---|---|---|
| `CacheRepository<T>` | Synchronous typed cache. Conforms to `RepositoryProtocol` and `CacheRepositoryProtocol`. | The API about 140 call sites already spell (`get`/`save`/`delete` without `await`). It sits on a `SynchronousCacheBacking`. |
| `AsyncCacheRepository<T>` | Asynchronous typed cache. Conforms to `RepositoryProtocol`. | The same envelope, TTL, codec and naming over ANY `CacheBacking`, including one that can only be async (a database, an object store). It reports an unreachable backing as itself (`CacheBackingFailure`), never as "not found". |
| `LocalFolderCacheBacking` | Files in one directory. | The default storage: local, offline, byte-for-byte what `CacheRepository` always wrote, with the `FileIOProfile` (`.plain`, `.atomic`, `.durable`). |
| `InMemoryCacheBacking` | An actor holding entries in memory. | Tests and session-scoped caches. Async only, so use it through `AsyncCacheRepository`. |
| `ObjectStoreCacheBacking` | Entries in an S3-compatible bucket, keyed by node id. | Evidence shared by several machines. It is built on `ObjectStoreClient`; `S3ObjectStoreClient` is the shipped client. |
| `SQLCacheBacking` (BackendKit) | Entries in a SQL table. | Lives in BackendKit because CoreKit cannot import it. It implements the same `CacheBacking`. |

## Why `CacheBacking` is not a `RepositoryProtocol`

A backing is **bytes by name**: no model, no identity, no envelope and no TTL. `RepositoryProtocol<ID, Model>` is a **typed model by id**.
The cache repositories are the consumers of a backing: they conform to `RepositoryProtocol` on top of it and own what a backing must
not know (envelope, TTL, codec, entry naming). A backing that were itself a `RepositoryProtocol` would make the cache a repository over a
repository with the model erased to `Data` and the id to `String`: the same two words meaning two different contracts. It also could not
report an entry's modification time (what raw-envelope TTL reads) or list entries without decoding every payload.

```swift
public protocol CacheBacking: Sendable {
    func fetch(_ entry: String) async throws -> CacheBlob?   // bytes + modified time, nil when absent
    func put(_ data: Data, as entry: String) async throws
    func delete(_ entry: String) async throws -> Bool
    func has(_ entry: String) async throws -> Bool
    func entries() async throws -> [String]
}
```

## Swapping the backing

Code written against `RepositoryProtocol` does not change when the backing does:

```swift
import CoreKit

struct Evidence: Codable, Sendable, Equatable { let wave: Int }

func record(_ evidence: Evidence, in cache: some RepositoryProtocol<String, Evidence>) async throws {
    try await cache.save("wave-\(evidence.wave)", data: evidence)
}

func demo(directory: URL) async throws {
    let local = CacheRepository<Evidence>("evidence", invalidateTime: .never, baseDirectory: directory)
    let memory = AsyncCacheRepository<Evidence>("evidence", invalidateTime: .never, backing: InMemoryCacheBacking())
    try await record(Evidence(wave: 1), in: local)
    try await record(Evidence(wave: 1), in: memory)
}
```

`CacheRepository(name)` with no directory is deprecated: pass `baseDirectory:`, pass the path layer with `in:` (see [paths](paths.md)),
or register one in DI. With none it throws `CacheLocationError`, never the documents folder. See the CHANGELOG.

## The S3 backing, end to end

`ObjectStoreCacheBacking` → `S3ObjectStoreClient` → an injected `S3Transport` → any S3-compatible endpoint (a self-hosted Garage, MinIO, ...).

**Addressing.** Every object is `bucket / node / entry`. The node id leads the key, so three machines writing the same entry write three
different keys and never overwrite each other. `ResourceAddress` renders it; the entry name is validated as a key path (`..`, empty
components and characters a store cannot carry are refused with `CacheBackingError.invalidEntryName`). A consolidation step reads another
node's entries with `backing.scoped(to: otherNode)`.

**Signing.** `S3ObjectStoreClient` sends path-style requests (`<endpoint>/<bucket>/<key>`) signed with AWS Signature Version 4
(`AWSSignatureV4`: SHA-256 payload hash, signed headers `host`, `x-amz-content-sha256`, `x-amz-date`, HMAC key derivation from the secret).
It signs for any endpoint that speaks SigV4, which is why a self-hosted store works with no SDK: only Foundation and swift-crypto. The
signer is checked against AWS's published worked example in `AWSSignatureV4Tests`.

**Injected, never defaulted.** The endpoint URL, the region the store signs for, the credentials (`S3Credentials`, whose secret never
appears in `description`, `debugDescription` or a mirror), the transport and the clock are all constructor arguments. There is no default
endpoint, bucket or key. The transport is a protocol (`S3Transport`): `URLSessionS3Transport` is the Foundation one, another stack can
provide its own, and tests use a fake.

**Failure behaviour.**
- A missing object is `nil` / `false` (`fetch`, `has`, `delete`), not an error.
- A refusal by the store is `S3ObjectStoreError.requestFailed(operation:status:code:)` with the store's own `<Code>`.
- A body the client cannot read is `S3ObjectStoreError.malformedResponse`; a truncated listing without a continuation token is reported, not looped on.
- Through `AsyncCacheRepository`, any backing failure surfaces as `CacheBackingFailure` carrying the operation, entry and underlying cause.
- Listing follows continuation tokens across pages.

**Pointing it at Garage.** Create a key and a bucket on the Garage node, allow the key on the bucket, and use Garage's S3 API address
(default port 3900) and its configured `s3_region`:

```swift
import CoreKit
import Foundation

func evidenceCache(
    endpoint: URL, region: String, accessKey: String, secretKey: String, node: NodeID
) throws -> AsyncCacheRepository<Evidence> {
    let client = try S3ObjectStoreClient(
        endpoint: endpoint,
        region: region,
        credentials: S3Credentials(accessKey: accessKey, secretKey: secretKey),
        transport: URLSessionS3Transport(),
        clock: { Date() })
    let backing = ObjectStoreCacheBacking(client: client, bucket: "evidence", node: node)
    return AsyncCacheRepository<Evidence>("evidence", invalidateTime: .never, envelope: .raw, backing: backing)
}
```

The values come from the host's settings and secrets, never from this package.

## Writing a backing, and proving it

A new backing (a database, another store) implements `CacheBacking` and runs the suites from `CoreKitTestSupport`:
`CacheBackingConformance` (the backing contract) and `CacheRepositoryConformance` (the same behaviour through the repository).
Both return the violations they found, so any test framework can assert `isEmpty`.
