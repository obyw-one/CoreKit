import XCTest
@testable import CoreKit

final class ResolveTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DI.reset()
    }

    override func tearDown() {
        DI.reset()
        super.tearDown()
    }

    // MARK: - @Resolve

    func testResolvePropertyWrapper() {
        Container.default.register(String.self) { _ in "resolved-value" }

        struct Holder {
            @Resolve var value: String
        }

        var holder = Holder()
        XCTAssertEqual(holder.value, "resolved-value")
    }

    func testResolvePropertyWrapperCachesValue() {
        var callCount = 0
        Container.default.register(Int.self) { _ in
            callCount += 1
            return 42
        }

        struct Holder {
            @Resolve var value: Int
        }

        var holder = Holder()
        _ = holder.value
        _ = holder.value
        _ = holder.value
        // Factory called only once due to caching in the property wrapper
        // (Note: Container also caches with .cached scope, so this is double-cached)
        XCTAssertEqual(callCount, 1)
    }

    func testResolvePropertyWrapperWithTransientScope() throws {
        var callCount = 0
        try Container.default.register(Int.self, scope: .transient) { _ in
            callCount += 1
            return callCount
        }

        struct Holder {
            @Resolve var value: Int
        }

        var holder = Holder()
        // First access resolves and caches in the property wrapper
        XCTAssertEqual(holder.value, 1)
        // Subsequent access returns cached value from property wrapper
        XCTAssertEqual(holder.value, 1)
    }

    // MARK: - @ResolveOptional

    func testResolveOptionalReturnsNilWhenNotRegistered() {
        struct Holder {
            @ResolveOptional var value: Double?
        }

        var holder = Holder()
        XCTAssertNil(holder.value)
    }

    func testResolveOptionalReturnsValueWhenRegistered() {
        Container.default.register(Double.self) { _ in 3.14 }

        struct Holder {
            @ResolveOptional var value: Double?
        }

        var holder = Holder()
        XCTAssertEqual(holder.value, 3.14)
    }

    // MARK: - DI.configure

    func testDIConfigureWithAssemblies() throws {
        struct TestAssembly: DIAssembly {
            func assemble(container: Container, environment: DIEnvironment) {
                container.register(String.self) { _ in
                    environment == .production ? "prod" : "mock"
                }
            }
        }

        DI.configure(for: .production, assemblies: [TestAssembly()])
        let prodValue: String = try Container.default.resolve()
        XCTAssertEqual(prodValue, "prod")

        DI.configure(for: .mock, assemblies: [TestAssembly()])
        let mockValue: String = try Container.default.resolve()
        XCTAssertEqual(mockValue, "mock")
    }

    // MARK: - DI.reset

    func testDIReset() {
        Container.default.register(String.self) { _ in "before-reset" }
        XCTAssertTrue(Container.default.isRegistered(String.self))

        DI.reset()
        XCTAssertFalse(Container.default.isRegistered(String.self))
    }

    // MARK: - Resolver.require

    func testResolverRequireReturnsValue() {
        Container.default.register(Int.self) { _ in 99 }

        let value: Int = Container.default.require(Int.self)
        XCTAssertEqual(value, 99)
    }
}
