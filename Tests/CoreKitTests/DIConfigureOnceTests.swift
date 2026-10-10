// DIConfigureOnceTests.swift — `DI.configureIfNeeded` configures the default
// container once (first caller wins, racers wait) and `DI.require` is the
// non-throwing resolve. Added for CoreKit 0.10.1 (shikki#1784 review: the
// once-mechanism is the kit's, the assemblies stay the app's).
import CoreKit
import Foundation
import Testing

private protocol PingProtocol: Sendable {
    var token: String { get }
}

private struct Ping: PingProtocol {
    let token: String
}

/// Counts how many times the assemblies closure ran, across threads.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// The lint's `empty_count` autofix spells `count == 0` as `isEmpty`.
    var isEmpty: Bool { isEmpty }
}

private struct PingAssembly: DIAssembly {
    let token: String
    func assemble(container: Container, environment: DIEnvironment) {
        container.register(PingProtocol.self) { _ in Ping(token: token) }
    }
}

// Nested under the serialized `@Resolve` suite: both swap `Container.default`,
// and Swift Testing runs top-level suites in parallel — a reset here while
// that suite resolves is a fatalError in `@Resolve` and a dead test process
// (the 89/89 and 60/60 "no_tests" runs of 2026-10-10).
extension ResolvePropertyWrapperTests {
@Suite("DI.configureIfNeeded / DI.require", .serialized)
struct DIConfigureOnceTests {
    @Test("the first call configures, the second returns the same configuration without running the assemblies again")
    func configuresOnce() throws {
        let previousDefault = Container.default
        defer { Container.default = previousDefault }
        DI.reset()
        #expect(!DI.isConfigured)
        let runs = Counter()

        DI.configureIfNeeded(for: .mock) {
            runs.bump()
            return [PingAssembly(token: "first")]
        }
        DI.configureIfNeeded(for: .mock) {
            runs.bump()
            return [PingAssembly(token: "second")]
        }

        #expect(runs.count == 1)
        #expect(DI.isConfigured)
        #expect(try Container.default.resolve(PingProtocol.self).token == "first")
    }

    @Test("reset arms it again")
    func resetArmsAgain() throws {
        let previousDefault = Container.default
        defer { Container.default = previousDefault }
        DI.reset()
        DI.configureIfNeeded(for: .mock) { [PingAssembly(token: "before")] }
        DI.reset()
        #expect(!DI.isConfigured)
        DI.configureIfNeeded(for: .mock) { [PingAssembly(token: "after")] }
        #expect(try Container.default.resolve(PingProtocol.self).token == "after")
    }

    @Test("a plain configure also counts as configured")
    func configureMarksConfigured() {
        let previousDefault = Container.default
        defer { Container.default = previousDefault }
        DI.reset()
        DI.configure(for: .production, assemblies: [PingAssembly(token: "plain")])
        #expect(DI.isConfigured)
        let runs = Counter()
        DI.configureIfNeeded(for: .mock) {
            runs.bump()
            return [PingAssembly(token: "ignored")]
        }
        #expect(runs.isEmpty, "configureIfNeeded must not replace a container the entry point composed")
    }

    @Test("racers on first use build one container, not many")
    func racersBuildOne() async throws {
        let previousDefault = Container.default
        defer { Container.default = previousDefault }
        DI.reset()
        let runs = Counter()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    DI.configureIfNeeded(for: .mock) {
                        runs.bump()
                        return [PingAssembly(token: "racer-\(index)")]
                    }
                }
            }
        }
        #expect(runs.count == 1)
        #expect(try Container.default.resolve(PingProtocol.self).token.hasPrefix("racer-"))
    }

    @Test("require resolves the registration like resolve, without a throw at the call site")
    func requireResolves() {
        let previousDefault = Container.default
        defer { Container.default = previousDefault }
        DI.reset()
        DI.configureIfNeeded(for: .mock) { [PingAssembly(token: "required")] }
        let ping = DI.require(PingProtocol.self)
        #expect(ping.token == "required")
        let inferred: PingProtocol = DI.require()
        #expect(inferred.token == "required")
    }
}
}
