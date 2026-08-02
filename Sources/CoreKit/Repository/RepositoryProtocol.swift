import Foundation

// MARK: - RepositoryProtocol

/// The generic Repository base — the abstract layer under every concrete
/// store, whatever its backend (file cache, network, Postgres, CLI shell).
///
/// Extracted 2026-08-02 (shikki PR #1505 review): shikki needed a
/// plans-table repository and, finding no base protocol here, re-implemented
/// the layer locally. The gaps this closes over `CacheRepositoryProtocol`:
///
///   * **Generic ID** — `CacheRepositoryProtocol` locks the key to `String`;
///     a Postgres- or API-backed store may key by `UUID`, `Int`, or a
///     compound value. `ID` is `Hashable & Sendable`.
///   * **Collection read** — querying a table returns rows, not one record;
///     `list()` is the missing surface.
///   * **Async-first** — a shell/network-backed store can only be async.
///     Synchronous conformers still satisfy these requirements (a sync
///     method fulfils an async protocol requirement), so `CacheRepository`
///     conforms without change to its call sites.
///   * **No policy baggage** — TTL/invalidation stays on the cache layer
///     (`InvalidateTime`), not here; a Postgres repository has no TTL.
///
/// `CacheRepositoryProtocol` refines this protocol with `ID == String` and
/// its cache-specific extras (`exists`, reachability-aware `get`).
public protocol RepositoryProtocol<ID, ModelType>: Sendable {
    associatedtype ID: Hashable & Sendable
    associatedtype ModelType: Codable & Sendable

    /// Fetch one record by id. Throws when the record does not exist.
    func get(_ id: ID) async throws -> ModelType

    /// Fetch every record this repository holds. Backends with natural
    /// filtering expose richer queries on the concrete type; the base
    /// surface guarantees only enumerability.
    func list() async throws -> [ModelType]

    /// Insert or replace the record stored under `id`.
    func save(_ id: ID, data: ModelType) async throws

    /// Remove the record stored under `id`. Throws when absent.
    func delete(_ id: ID) async throws
}
