import CoreKit
import Foundation

// MARK: - CacheBackingHarness

/// A backing wired for the contract suite: the backing itself, and the one
/// thing the suite cannot do through the protocol — make an entry older.
public struct CacheBackingHarness: Sendable {
    public let label: String
    public let backing: any CacheBacking
    /// Makes the entry's modification time `seconds` earlier.
    public let age: @Sendable (String, TimeInterval) async throws -> Void

    public init(
        label: String,
        backing: any CacheBacking,
        age: @escaping @Sendable (String, TimeInterval) async throws -> Void
    ) {
        self.label = label
        self.backing = backing
        self.age = age
    }
}

// MARK: - CacheBackingConformance

/// What a ``CacheBacking`` must do, whatever it stores into (BR-RP-11).
///
/// A database backing in BackendKit and an object-store backing in NetKit run
/// this exact suite from their own test targets: that is how "the same cache
/// API over local, db and object-store" (T-11) stays a measured fact rather than an
/// intention. Each check returns the violations it observed; empty is a pass.
public enum CacheBackingConformance {

    public enum Check: String, CaseIterable, Sendable, CustomStringConvertible {
        case missingEntryReadsNil
        case bytesRoundTripExactly
        case overwriteReplaces
        case hasTracksState
        case deleteReportsPresence
        case entriesListsOnlyHeldEntries
        case modifiedIsReported
        case ageMovesModifiedBack
        case entriesAreIndependent
        case concurrentWritersAreSafe

        public var description: String { rawValue }
    }

    public static func run(_ check: Check, on harness: CacheBackingHarness) async -> [String] {
        let collector = Collector(prefix: "\(harness.label) / \(check.rawValue)")
        guard let implementation = implementations[check] else {
            collector.fail("no implementation registered for this check")
            return collector.violations
        }
        do {
            try await implementation(harness, collector)
        } catch {
            collector.fail("threw unexpectedly: \(error)")
        }
        return collector.violations
    }

    public static func runAll(on harness: CacheBackingHarness) async -> [String] {
        var all: [String] = []
        for check in Check.allCases { all += await run(check, on: harness) }
        return all
    }

    // MARK: Collector

    /// The violations of ONE check, collected on that check's task alone: it is
    /// created, filled and read inside a single `run`, never shared.
    private final class Collector {
        let prefix: String
        private(set) var violations: [String] = []

        init(prefix: String) {
            self.prefix = prefix
        }

        func fail(_ message: String) {
            violations.append("\(prefix): \(message)")
        }

        func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { fail(message()) }
        }
    }

    // MARK: Checks

    private typealias Implementation = @Sendable (CacheBackingHarness, Collector) async throws -> Void

    /// One implementation per check; a test asserts every case has an entry.
    private static let implementations: [Check: Implementation] = [
        .missingEntryReadsNil: missingEntryReadsNil,
        .bytesRoundTripExactly: bytesRoundTripExactly,
        .overwriteReplaces: overwriteReplaces,
        .hasTracksState: hasTracksState,
        .deleteReportsPresence: deleteReportsPresence,
        .entriesListsOnlyHeldEntries: entriesListsOnlyHeldEntries,
        .modifiedIsReported: modifiedIsReported,
        .ageMovesModifiedBack: ageMovesModifiedBack,
        .entriesAreIndependent: entriesAreIndependent,
        .concurrentWritersAreSafe: concurrentWritersAreSafe,
    ]

    /// Every case has an implementation (asserted by the suite's own test).
    public static var implementedChecks: [Check] { Check.allCases.filter { implementations[$0] != nil } }

    private static func unique(_ stem: String) -> String {
        "\(stem)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private static func missingEntryReadsNil(_ harness: CacheBackingHarness, _ check: Collector) async throws {
        let entry = unique("missing")
        check.expect(try await harness.backing.fetch(entry) == nil, "fetch of an absent entry must be nil, not an error")
        check.expect(!(try await harness.backing.has(entry)), "has of an absent entry must be false")
    }

    private static func bytesRoundTripExactly(_ harness: CacheBackingHarness, _ check: Collector) async throws {
        let everyByte = Data((0...255).map { UInt8($0) })
        let large = Data(repeating: 0xAB, count: 1_048_576)
        for (label, data) in [("empty", Data()), ("every byte value", everyByte), ("1 MiB", large)] {
            let entry = unique("bytes")
            try await harness.backing.put(data, as: entry)
            check.expect(try await harness.backing.fetch(entry)?.data == data, "\(label) did not round-trip byte for byte")
        }
    }

    private static func overwriteReplaces(_ harness: CacheBackingHarness, _ check: Collector) async throws {
        let entry = unique("overwrite")
        try await harness.backing.put(Data("first".utf8), as: entry)
        try await harness.backing.put(Data("second".utf8), as: entry)
        check.expect(
            try await harness.backing.fetch(entry)?.data == Data("second".utf8), "the second put did not replace the first")
        check.expect(
            try await harness.backing.entries().filter { $0 == entry }.count == 1, "an overwrite produced a second entry")
    }

    private static func hasTracksState(_ harness: CacheBackingHarness, _ check: Collector) async throws {
        let entry = unique("has")
        try await harness.backing.put(Data("x".utf8), as: entry)
        check.expect(try await harness.backing.has(entry), "has is false right after put")
        _ = try await harness.backing.delete(entry)
        check.expect(!(try await harness.backing.has(entry)), "has is true after delete")
    }

    private static func deleteReportsPresence(_ harness: CacheBackingHarness, _ check: Collector) async throws {
        let entry = unique("delete")
        try await harness.backing.put(Data("x".utf8), as: entry)
        check.expect(try await harness.backing.delete(entry), "delete of a held entry must return true")
        check.expect(!(try await harness.backing.delete(entry)), "delete of an absent entry must return false, not throw")
        check.expect(try await harness.backing.fetch(entry) == nil, "the entry is still readable after delete")
    }

    private static func entriesListsOnlyHeldEntries(_ harness: CacheBackingHarness, _ check: Collector) async throws {
        let kept = unique("kept")
        let dropped = unique("dropped")
        try await harness.backing.put(Data("1".utf8), as: kept)
        try await harness.backing.put(Data("2".utf8), as: dropped)
        _ = try await harness.backing.delete(dropped)
        let listed = try await harness.backing.entries()
        check.expect(listed.contains(kept), "entries() omits a held entry")
        check.expect(!listed.contains(dropped), "entries() lists a deleted entry")
        check.expect(Set(listed).count == listed.count, "entries() lists an entry twice")
    }

    private static func modifiedIsReported(_ harness: CacheBackingHarness, _ check: Collector) async throws {
        let entry = unique("modified")
        let before = Date().addingTimeInterval(-120)
        try await harness.backing.put(Data("x".utf8), as: entry)
        let modified = try await harness.backing.fetch(entry)?.modified
        check.expect(modified != nil, "a backing must report when an entry was written, or raw-envelope TTL cannot work")
        if let modified {
            check.expect(modified > before && modified < Date().addingTimeInterval(120), "modified \(modified) is not about now")
        }
    }

    private static func ageMovesModifiedBack(_ harness: CacheBackingHarness, _ check: Collector) async throws {
        let entry = unique("age")
        try await harness.backing.put(Data("x".utf8), as: entry)
        guard let fresh = try await harness.backing.fetch(entry)?.modified else {
            return check.fail("no modification date to age")
        }
        try await harness.age(entry, 7200)
        guard let aged = try await harness.backing.fetch(entry)?.modified else {
            return check.fail("ageing an entry lost its modification date")
        }
        let moved = fresh.timeIntervalSince(aged)
        check.expect(abs(moved - 7200) < 5, "ageing by 7200s moved modified by \(moved)s")
    }

    private static func entriesAreIndependent(_ harness: CacheBackingHarness, _ check: Collector) async throws {
        let a = unique("a")
        let b = unique("b")
        try await harness.backing.put(Data("A".utf8), as: a)
        try await harness.backing.put(Data("B".utf8), as: b)
        _ = try await harness.backing.delete(a)
        check.expect(try await harness.backing.fetch(b)?.data == Data("B".utf8), "deleting one entry disturbed another")
    }

    private static func concurrentWritersAreSafe(_ harness: CacheBackingHarness, _ check: Collector) async throws {
        let backing = harness.backing
        let entries = (0..<16).map { _ in unique("concurrent") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for entry in entries {
                group.addTask { try await backing.put(Data(entry.utf8), as: entry) }
            }
            try await group.waitForAll()
        }
        for entry in entries {
            check.expect(
                try await backing.fetch(entry)?.data == Data(entry.utf8), "concurrent put of \(entry) was lost or mixed up")
        }
    }
}
