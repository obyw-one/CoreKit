import Foundation
import Testing
@testable import CoreKit

// MARK: - InMemoryRepositoryTests

private struct Row: Codable, Sendable, Equatable {
    let id: String
    let value: Int
}

@Suite("InMemoryRepository")
struct InMemoryRepositoryTests {
    @Test("save then get round-trips")
    func saveGetRoundTrip() async throws {
        let repo = InMemoryRepository<String, Row>()
        let row = Row(id: "a", value: 1)
        try await repo.save("a", data: row)
        #expect(try await repo.get("a") == row)
    }

    @Test("get on a missing id throws notFound")
    func getMissingThrows() async {
        let repo = InMemoryRepository<String, Row>()
        await #expect(throws: RepositoryError.notFound(id: "ghost")) {
            _ = try await repo.get("ghost")
        }
    }

    @Test("list preserves first-insertion order across upserts")
    func listPreservesInsertionOrder() async throws {
        let repo = InMemoryRepository<String, Row>()
        try await repo.save("a", data: Row(id: "a", value: 1))
        try await repo.save("b", data: Row(id: "b", value: 2))
        // Upsert "a" — order must NOT change, value must.
        try await repo.save("a", data: Row(id: "a", value: 99))
        let listed = try await repo.list()
        #expect(listed == [Row(id: "a", value: 99), Row(id: "b", value: 2)])
    }

    @Test("delete removes the record and later get throws")
    func deleteRemoves() async throws {
        let repo = InMemoryRepository<String, Row>()
        try await repo.save("a", data: Row(id: "a", value: 1))
        try await repo.delete("a")
        #expect(try await repo.list().isEmpty)
        await #expect(throws: RepositoryError.notFound(id: "a")) {
            _ = try await repo.get("a")
        }
    }

    @Test("delete on a missing id throws notFound")
    func deleteMissingThrows() async {
        let repo = InMemoryRepository<String, Row>()
        await #expect(throws: RepositoryError.notFound(id: "ghost")) {
            try await repo.delete("ghost")
        }
    }

    @Test("saveCount counts raw writes, ignoring upsert collapse")
    func saveCountIsRaw() async throws {
        let repo = InMemoryRepository<String, Row>()
        try await repo.save("a", data: Row(id: "a", value: 1))
        try await repo.save("a", data: Row(id: "a", value: 2))
        try await repo.save("b", data: Row(id: "b", value: 3))
        #expect(await repo.saveCount == 3)
        #expect(try await repo.list().count == 2)
    }

    @Test("generic ID — keyed by Int works identically")
    func intKeyed() async throws {
        let repo = InMemoryRepository<Int, Row>()
        try await repo.save(7, data: Row(id: "seven", value: 7))
        #expect(try await repo.get(7).id == "seven")
    }
}
