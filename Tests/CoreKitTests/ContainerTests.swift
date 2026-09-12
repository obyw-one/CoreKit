import XCTest
@testable import CoreKit

final class ContainerTests: XCTestCase {
    var container: Container!

    override func setUp() {
        super.setUp()
        container = Container(name: "Test")
    }

    override func tearDown() {
        container.cleanup()
        container = nil
        super.tearDown()
    }

    // MARK: - Registration & Resolution

    func testRegisterAndResolve() throws {
        container.register(String.self) { _ in "Hello" }

        let result: String = try container.resolve()
        XCTAssertEqual(result, "Hello")
    }

    func testResolveUnregisteredTypeThrows() {
        XCTAssertThrowsError(try container.resolve(Int.self)) { error in
            guard case ContainerError.notRegistered = error else {
                XCTFail("Expected notRegistered error, got \(error)")
                return
            }
        }
    }

    func testResolveOptionalReturnsNilWhenNotRegistered() {
        let result: Int? = container.resolveOptional(Int.self)
        XCTAssertNil(result)
    }

    func testResolveOptionalReturnsValueWhenRegistered() {
        container.register(Int.self) { _ in 42 }
        let result: Int? = container.resolveOptional(Int.self)
        XCTAssertEqual(result, 42)
    }

    // MARK: - Named Registrations

    func testNamedRegistrations() throws {
        container.register(String.self, name: "greeting") { _ in "Hello" }
        container.register(String.self, name: "farewell") { _ in "Goodbye" }

        let greeting: String = try container.resolve(String.self, name: "greeting")
        let farewell: String = try container.resolve(String.self, name: "farewell")

        XCTAssertEqual(greeting, "Hello")
        XCTAssertEqual(farewell, "Goodbye")
    }

    // MARK: - Scopes

    func testCachedScopeReturnsSameInstance() throws {
        var count = 0
        try container.register(Int.self, scope: .cached) { _ in
            count += 1
            return count
        }

        let a: Int = try container.resolve()
        let b: Int = try container.resolve()
        XCTAssertEqual(a, b)
        XCTAssertEqual(count, 1)
    }

    func testTransientScopeReturnsDifferentInstances() throws {
        var count = 0
        try container.register(Int.self, scope: .transient) { _ in
            count += 1
            return count
        }

        let a: Int = try container.resolve()
        let b: Int = try container.resolve()
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Circular Dependency Detection

    func testCircularDependencyDetection() {
        container.register(String.self) { resolver in
            let _: Int = try resolver.resolve(Int.self)
            return "unreachable"
        }
        container.register(Int.self) { resolver in
            let _: String = try resolver.resolve(String.self)
            return 0
        }

        XCTAssertThrowsError(try container.resolve(String.self)) { error in
            guard case ContainerError.circularDependency = error else {
                XCTFail("Expected circularDependency error, got \(error)")
                return
            }
        }
    }

    // MARK: - Thread Safety

    func testConcurrentResolvesDoNotFalsePositiveCircular() {
        // Register two independent types
        container.register(String.self) { _ in
            Thread.sleep(forTimeInterval: 0.01) // simulate work
            return "hello"
        }
        container.register(Int.self) { _ in
            Thread.sleep(forTimeInterval: 0.01)
            return 42
        }

        let group = DispatchGroup()
        var stringResult: String?
        var intResult: Int?
        var stringError: Error?
        var intError: Error?

        // Resolve on two threads concurrently — should NOT false-detect circular dependency
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { stringResult = try self.container.resolve(String.self) } catch { stringError = error }
        }

        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { intResult = try self.container.resolve(Int.self) } catch { intError = error }
        }

        group.wait()

        XCTAssertNil(stringError, "String resolve should not fail: \(stringError?.localizedDescription ?? "")")
        XCTAssertNil(intError, "Int resolve should not fail: \(intError?.localizedDescription ?? "")")
        XCTAssertEqual(stringResult, "hello")
        XCTAssertEqual(intResult, 42)
    }

    func testConcurrentResolvesOfSameTypeSucceed() throws {
        var callCount = 0
        let countLock = NSLock()
        try container.register(String.self, scope: .cached) { _ in
            countLock.lock()
            callCount += 1
            countLock.unlock()
            return "shared"
        }

        let group = DispatchGroup()
        let iterations = 50
        var results: [String?] = Array(repeating: nil, count: iterations)

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                results[i] = try? self.container.resolve(String.self)
            }
        }

        group.wait()

        // All should succeed
        for i in 0..<iterations {
            XCTAssertEqual(results[i], "shared", "Iteration \(i) should resolve successfully")
        }
    }

    // MARK: - Parent Container

    func testParentContainerFallback() throws {
        let parent = Container(name: "Parent")
        parent.register(String.self) { _ in "FromParent" }

        let child = Container(name: "Child", parent: parent)

        let result: String = try child.resolve()
        XCTAssertEqual(result, "FromParent")
    }

    // MARK: - Instance Registration

    func testRegisterInstance() throws {
        container.registerInstance(99, for: Int.self)
        let result: Int = try container.resolve()
        XCTAssertEqual(result, 99)
    }

    // MARK: - isRegistered

    func testIsRegistered() {
        XCTAssertFalse(container.isRegistered(String.self))
        container.register(String.self) { _ in "test" }
        XCTAssertTrue(container.isRegistered(String.self))
    }

    // MARK: - Cleanup

    func testCleanupRemovesAllRegistrations() {
        container.register(String.self) { _ in "test" }
        XCTAssertTrue(container.isRegistered(String.self))

        container.cleanup()
        XCTAssertFalse(container.isRegistered(String.self))
    }

    func testRemoveSpecificRegistration() {
        container.register(String.self) { _ in "test" }
        container.register(Int.self) { _ in 42 }

        container.remove(String.self)

        XCTAssertFalse(container.isRegistered(String.self))
        XCTAssertTrue(container.isRegistered(Int.self))
    }

    // MARK: - Reset Cache

    // MARK: - Lazy Assemblies

    func testLazyAssemblyTriggeredOnResolveMiss() throws {
        let assembly = StubAssembly(registerBlock: { container, _ in
            container.register(String.self) { _ in "lazy-loaded" }
        })
        container.addLazyAssembly(assembly, environment: .production)

        // Not yet assembled — but resolve should trigger it
        let result: String = try container.resolve()
        XCTAssertEqual(result, "lazy-loaded")
        XCTAssertTrue(assembly.assembled)
    }

    func testLazyAssemblyNotTriggeredWhenTypeAlreadyRegistered() throws {
        container.register(String.self) { _ in "eager" }

        let assembly = StubAssembly(registerBlock: { container, _ in
            container.register(Int.self) { _ in 99 }
        })
        container.addLazyAssembly(assembly, environment: .production)

        let result: String = try container.resolve()
        XCTAssertEqual(result, "eager")
        XCTAssertFalse(assembly.assembled, "Lazy assembly should not fire when type is already registered")
    }

    func testLazyAssemblyOnlyTriggersMinimumNeeded() throws {
        let assembly1 = StubAssembly(registerBlock: { container, _ in
            container.register(String.self) { _ in "from-assembly-1" }
        })
        let assembly2 = StubAssembly(registerBlock: { container, _ in
            container.register(Int.self) { _ in 42 }
        })
        container.addLazyAssembly(assembly1, environment: .production)
        container.addLazyAssembly(assembly2, environment: .production)

        // Resolve String — should trigger assembly1, NOT assembly2
        let result: String = try container.resolve()
        XCTAssertEqual(result, "from-assembly-1")
        XCTAssertTrue(assembly1.assembled)
        XCTAssertFalse(assembly2.assembled, "Second assembly should not fire when first provides the type")
    }

    func testCleanupClearsPendingAssemblies() {
        let assembly = StubAssembly(registerBlock: { container, _ in
            container.register(String.self) { _ in "test" }
        })
        container.addLazyAssembly(assembly, environment: .production)
        container.cleanup()

        // After cleanup, resolve should fail — assembly was discarded
        XCTAssertThrowsError(try container.resolve(String.self))
        XCTAssertFalse(assembly.assembled)
    }

    func testDIConfigureWithLazyAssemblies() throws {
        let eager = StubAssembly(registerBlock: { container, _ in
            container.register(String.self) { _ in "eager" }
        })
        let lazy = StubAssembly(registerBlock: { container, _ in
            container.register(Int.self) { _ in 42 }
        })

        DI.configure(for: .production, assemblies: [eager], lazyAssemblies: [lazy])

        XCTAssertTrue(eager.assembled)
        XCTAssertFalse(lazy.assembled, "Lazy assembly should not be assembled at configure time")

        let intResult: Int = try Container.default.resolve()
        XCTAssertEqual(intResult, 42)
        XCTAssertTrue(lazy.assembled, "Lazy assembly should be assembled on first resolve")
    }

    // MARK: - Reset Cache

    func testResetCacheRecreateCachedInstances() throws {
        var count = 0
        container.register(Int.self) { _ in
            count += 1
            return count
        }

        let first: Int = try container.resolve()
        XCTAssertEqual(first, 1)

        container.resetCache()

        let second: Int = try container.resolve()
        XCTAssertEqual(second, 2)
    }
}

// MARK: - Test Helpers

private final class StubAssembly: DIAssembly {
    private(set) var assembled = false
    private let registerBlock: (Container, DIEnvironment) -> Void

    init(registerBlock: @escaping (Container, DIEnvironment) -> Void) {
        self.registerBlock = registerBlock
    }

    func assemble(container: Container, environment: DIEnvironment) {
        assembled = true
        registerBlock(container, environment)
    }
}
