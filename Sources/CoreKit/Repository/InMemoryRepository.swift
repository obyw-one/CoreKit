import Foundation

// MARK: - RepositoryError

/// Failures shared by backend-agnostic `RepositoryProtocol` conformers.
///
/// `CacheRepositoryError` stays on the cache layer (it encodes file-IO
/// specifics); this enum covers the semantic contract every repository
/// shares: a lookup can miss, and some stores forbid some verbs.
public enum RepositoryError: Error, Sendable, Equatable {
    /// No record stored under the requested id.
    case notFound(id: String)
    /// The concrete store forbids this operation by design (e.g. `delete`
    /// on an append-only audit store). `operation` names the refused verb.
    case unsupported(operation: String, reason: String)
}

// MARK: - InMemoryRepository

/// The fleet's ONE in-memory `RepositoryProtocol` conformer (2026-08-07,
/// shikki PR #1533 review): every plugin that needs a dictionary-backed
/// store — test doubles, session-scoped caches, staging buffers — consumes
/// this instead of hand-rolling the same `[ID: Model]` + insertion-order
/// bookkeeping again.
///
/// Semantics:
///   * `save` upserts — last write wins per id.
///   * `list()` preserves FIRST-insertion order across upserts, matching
///     append-only-log projections (a JSONL ledger replayed into memory
///     lists entries in the order they first appeared).
///   * `get`/`delete` throw `RepositoryError.notFound` on a miss.
public actor InMemoryRepository<ID: Hashable & Sendable, ModelType: Codable & Sendable>:
    RepositoryProtocol
{

    private var storage: [ID: ModelType] = [:]
    private var insertionOrder: [ID] = []
    /// Total `save` calls accepted, ignoring upsert collapse. Lets an
    /// append-only consumer assert raw write counts in tests.
    public private(set) var saveCount: Int = 0

    public init() {}

    // MARK: - RepositoryProtocol

    public func get(_ id: ID) async throws -> ModelType {
        guard let value = storage[id] else {
            throw RepositoryError.notFound(id: String(describing: id))
        }
        return value
    }

    public func list() async throws -> [ModelType] {
        insertionOrder.compactMap { storage[$0] }
    }

    public func save(_ id: ID, data: ModelType) async throws {
        if storage[id] == nil { insertionOrder.append(id) }
        storage[id] = data
        saveCount += 1
    }

    public func delete(_ id: ID) async throws {
        guard storage.removeValue(forKey: id) != nil else {
            throw RepositoryError.notFound(id: String(describing: id))
        }
        insertionOrder.removeAll { $0 == id }
    }
}
