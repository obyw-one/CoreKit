import CoreKit
import CoreKitTestSupport
import Foundation
import Testing

// MARK: - CacheBackingConformanceTests

@Suite("Cache behaviour is the same over every backing (T-11)")
struct CacheBackingConformanceTests {

    @Test(
        "the cache behaviour suite holds over each backing and facade",
        arguments: BackingKind.allCases, CacheRepositoryConformance.Check.allCases)
    func repositoryBehaviour(kind: BackingKind, check: CacheRepositoryConformance.Check) async throws {
        let built = try BackingHarnesses.build(kind)
        defer { built.tearDown() }
        let violations = await CacheRepositoryConformance.run(check, on: built.repository)
        #expect(violations.isEmpty, "\(violations)")
        let objections = await built.storeObjections()
        #expect(objections.isEmpty, "the store would have rejected a request: \(objections)")
    }

    @Test(
        "the backing contract holds over each backing",
        arguments: BackingKind.allCases, CacheBackingConformance.Check.allCases)
    func backingContract(kind: BackingKind, check: CacheBackingConformance.Check) async throws {
        let built = try BackingHarnesses.build(kind)
        defer { built.tearDown() }
        let violations = await CacheBackingConformance.run(check, on: built.backing)
        #expect(violations.isEmpty, "\(violations)")
        let objections = await built.storeObjections()
        #expect(objections.isEmpty, "the store would have rejected a request: \(objections)")
    }

    @Test("every shipped backing is in the population")
    func populationIsComplete() {
        #expect(BackingKind.allCases.count == 7)
        #expect(CacheRepositoryConformance.Check.allCases.count == 17)
        #expect(CacheBackingConformance.Check.allCases.count == 10)
    }

    @Test("every check in both suites has an implementation: none can be silently skipped")
    func everyCheckIsImplemented() {
        #expect(CacheRepositoryConformance.implementedChecks == CacheRepositoryConformance.Check.allCases)
        #expect(CacheBackingConformance.implementedChecks == CacheBackingConformance.Check.allCases)
    }
}
