import Foundation
import Testing
@testable import CoreKit

private protocol Greeter: Sendable { var id: Int { get } }
private struct ValueGreeter: Greeter { let id: Int }
private final class ClassGreeter: Greeter, @unchecked Sendable { let id: Int; init(id: Int) { self.id = id } }

/// Counts how many times a factory ran.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() -> Int { lock.withLock { count += 1; return count } }
}

@Suite("Container .weak scope — a weak reference to a value type is a caller error, not a silent .transient")
struct ContainerWeakScopeTests {

    @Test("a concrete value type under the weak scope is refused the first time it is resolved, and the factory is not re-run")
    func aStructWeakThrowsAtResolve() throws {
        let container = Container(name: "weak")
        let counter = Counter()
        try container.register(ValueGreeter.self, scope: .weak) { _ in ValueGreeter(id: counter.bump()) }
        #expect(throws: ContainerError.self) { _ = try container.resolve(ValueGreeter.self) }
        #expect(counter.value == 1)
    }

    @Test("a protocol registered weak whose factory returns a struct fails at resolve, and says why")
    func structBehindAProtocolThrowsAtResolve() throws {
        let container = Container(name: "weak")
        let counter = Counter()
        try container.register((any Greeter).self, scope: .weak) { _ in ValueGreeter(id: counter.bump()) }
        let error = #expect(throws: ContainerError.self) { _ = try container.resolve((any Greeter).self) }
        guard case .invalidRegistration(let message)? = error else {
            Issue.record("expected invalidRegistration, got \(String(describing: error))")
            return
        }
        #expect(message.contains("weak"))
        #expect(counter.value == 1)
    }

    @Test("a class under the weak scope is shared while something holds it")
    func classIsSharedWhileHeld() throws {
        let container = Container(name: "weak")
        let counter = Counter()
        try container.register(ClassGreeter.self, scope: .weak) { _ in ClassGreeter(id: counter.bump()) }
        let first = try container.resolve(ClassGreeter.self)
        let second = try container.resolve(ClassGreeter.self)
        #expect(first === second)
        #expect(counter.value == 1, "the factory re-ran although the instance was alive")
    }

    @Test("the same struct under .transient and .cached still works")
    func otherScopesAreUnaffected() throws {
        let container = Container(name: "weak")
        try container.register(ValueGreeter.self, name: "t", scope: .transient) { _ in ValueGreeter(id: 1) }
        try container.register(ValueGreeter.self, name: "c", scope: .cached) { _ in ValueGreeter(id: 2) }
        #expect(try container.resolve(ValueGreeter.self, name: "t").id == 1)
        #expect(try container.resolve(ValueGreeter.self, name: "c").id == 2)
    }
}
