// ContainerBehaviourTests.swift — the 26-case container suite that lived in
// WabiSabi/WabiSabiTests/Core/DI while WabiSabi carried a fork of this
// container. The fork is deleted (obyw-one/WabiSabi#115); the suite comes home
// to the package that owns the behaviour (operator review r4228519521).
//
//  ContainerTests.swift
//  WabiSabiTests
//
//  Created by Jeoffrey Thirot on 20/02/2026.
//

import CoreKit
import Foundation
import Testing

private protocol TestServiceProtocol: Sendable {
    var id: String { get }
}

private final class TestService: TestServiceProtocol, Sendable {
    let id: String
    init(id: String = UUID().uuidString) {
        self.id = id
    }
}

private protocol TestRepositoryProtocol: Sendable {
    var data: String { get }
}

private final class TestRepository: TestRepositoryProtocol, Sendable {
    let data: String
    init(data: String = "test-data") {
        self.data = data
    }
}

private protocol TestUseCaseProtocol: Sendable {
    func execute() -> String
}

private final class TestUseCase: TestUseCaseProtocol, Sendable {
    private let service: TestServiceProtocol
    private let repository: TestRepositoryProtocol

    init(service: TestServiceProtocol, repository: TestRepositoryProtocol) {
        self.service = service
        self.repository = repository
    }

    func execute() -> String {
        "\(service.id)-\(repository.data)"
    }
}

// MARK: - Circular Dependency Models

private protocol CircularA: Sendable { var b: CircularB? { get } }
private protocol CircularB: Sendable { var a: CircularA? { get } }

private final class ConcreteCircularA: CircularA, @unchecked Sendable {
    var b: CircularB?
    init(b: CircularB? = nil) { self.b = b }
}

private final class ConcreteCircularB: CircularB, @unchecked Sendable {
    var a: CircularA?
    init(a: CircularA? = nil) { self.a = a }
}

// MARK: - Test Suite

@Suite("Container — the behaviour suite WabiSabi's fork carried (obyw-one/WabiSabi#115 review)")
@MainActor
struct ContainerBehaviourTests {

    // MARK: - Helper

    private func createFreshContainer() -> Container {
        Container(name: "TestContainer")
    }

    // MARK: - Registration Tests

    @Suite("Registration")
    @MainActor struct RegistrationTests {

        @Test("Register and resolve basic service")
        func testRegisterAndResolveBasic() async throws {
            let container = Container(name: "TestContainer")

            container.register(TestServiceProtocol.self) { _ in
                TestService(id: "test-123")
            }

            let service = try container.resolve(TestServiceProtocol.self)

            #expect(service.id == "test-123")
        }

        @Test("Register with name")
        func testRegisterWithName() async throws {
            let container = Container(name: "TestContainer")

            container.register(TestServiceProtocol.self, name: "primary") { _ in
                TestService(id: "primary")
            }

            container.register(TestServiceProtocol.self, name: "secondary") { _ in
                TestService(id: "secondary")
            }

            let primary = try container.resolve(TestServiceProtocol.self, name: "primary")
            let secondary = try container.resolve(TestServiceProtocol.self, name: "secondary")

            #expect(primary.id == "primary")
            #expect(secondary.id == "secondary")
        }

    }

    // MARK: - Resolution Tests

    @Suite("Resolution")
    @MainActor struct ResolutionTests {

        @Test("Resolve throws when not registered")
        func testResolveNotRegistered() async {
            let container = Container(name: "TestContainer")

            do {
                _ = try container.resolve(TestServiceProtocol.self)
                Issue.record("Should throw notRegistered error")
            } catch let error as ContainerError {
                if case .notRegistered = error {
                    #expect(true)
                } else {
                    Issue.record("Wrong error type: \(error)")
                }
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }

        @Test("Resolve optional returns nil when not registered")
        func testResolveOptionalNotRegistered() async {
            let container = Container(name: "TestContainer")

            let service = container.resolveOptional(TestServiceProtocol.self)

            #expect(service == nil)
        }

        @Test("Resolve optional returns value when registered")
        func testResolveOptionalRegistered() async throws {
            let container = Container(name: "TestContainer")

            container.register(TestServiceProtocol.self) { _ in
                TestService(id: "optional-test")
            }

            let service = container.resolveOptional(TestServiceProtocol.self)

            #expect(service?.id == "optional-test")
        }
    }

    // MARK: - Scope Tests

    @Suite("Registration Scopes")
    @MainActor struct ScopeTests {

        @Test("Transient creates new instance each time")
        func testTransientScope() async throws {
            let container = Container(name: "TestContainer")

            try container.register(TestServiceProtocol.self, scope: .transient) { _ in
                TestService()
            }

            let instance1 = try container.resolve(TestServiceProtocol.self)
            let instance2 = try container.resolve(TestServiceProtocol.self)

            #expect(instance1.id != instance2.id, "Transient should create new instances")
        }

        @Test("Cached returns same instance each time")
        func testCachedScope() async throws {
            let container = Container(name: "TestContainer")

            try container.register(TestServiceProtocol.self, scope: .cached) { _ in
                TestService()
            }

            let instance1 = try container.resolve(TestServiceProtocol.self)
            let instance2 = try container.resolve(TestServiceProtocol.self)

            #expect(instance1.id == instance2.id, "Cached should return same instance")
        }

        @Test("Weak allows instance to be deallocated")
        func testWeakScope() async throws {
            let container = Container(name: "TestContainer")

            try container.register(TestServiceProtocol.self, scope: .weak) { _ in
                TestService()
            }

            let instance1 = try container.resolve(TestServiceProtocol.self)
            let id1 = instance1.id

            // Clear strong reference
            // Note: In practice, weak scope allows the instance to be deallocated
            // when no strong references exist

            let instance2 = try container.resolve(TestServiceProtocol.self)

            // Both should be valid (weak references are kept while strongly held)
            #expect(instance1.id == id1)
            #expect(instance2.id == id1)
        }

        @Test("Default scope is cached")
        func testDefaultScope() async throws {
            let container = Container(name: "TestContainer")

            // Register without explicit scope (convenience method defaults to .cached)
            container.register(TestServiceProtocol.self) { _ in
                TestService()
            }

            let instance1 = try container.resolve(TestServiceProtocol.self)
            let instance2 = try container.resolve(TestServiceProtocol.self)

            #expect(instance1.id == instance2.id, "Default scope should be cached")
        }
    }

    // MARK: - Resolver Protocol Tests (Swinject-style)

    @Suite("Resolver Protocol")
    @MainActor struct ResolverTests {

        @Test("Factory receives resolver parameter")
        func testFactoryReceivesResolver() async throws {
            let container = Container(name: "TestContainer")

            // Register dependency first
            try container.register(TestRepositoryProtocol.self, scope: .cached) { _ in
                TestRepository(data: "repo-data")
            }

            // Register service that uses resolver to get dependency
            container.register(TestUseCaseProtocol.self) { resolver in
                let repository = try resolver.resolve(TestRepositoryProtocol.self)
                return TestUseCase(
                    service: TestService(id: "from-resolver"),
                    repository: repository
                )
            }

            let useCase = try container.resolve(TestUseCaseProtocol.self)

            #expect(useCase.execute() == "from-resolver-repo-data")
        }

        @Test("Resolver can resolve multiple dependencies")
        func testResolverMultipleDependencies() async throws {
            let container = Container(name: "TestContainer")

            container.register(TestServiceProtocol.self) { _ in
                TestService(id: "service-1")
            }

            container.register(TestRepositoryProtocol.self) { _ in
                TestRepository(data: "repo-1")
            }

            container.register(TestUseCaseProtocol.self) { resolver in
                let service = try resolver.resolve(TestServiceProtocol.self)
                let repository = try resolver.resolve(TestRepositoryProtocol.self)
                return TestUseCase(service: service, repository: repository)
            }

            let useCase = try container.resolve(TestUseCaseProtocol.self)

            #expect(useCase.execute() == "service-1-repo-1")
        }
    }

    // MARK: - Circular Dependency Detection Tests

    @Suite("Circular Dependency Detection")
    @MainActor struct CircularDependencyTests {

        @Test("Detects direct circular dependency (A → A)")
        func testDirectCircularDependency() async throws {
            let container = Container(name: "TestContainer")

            // Self-referencing registration
            container.register(CircularA.self) { resolver in
                let a = ConcreteCircularA()
                a.b = try? resolver.resolve(CircularB.self)
                return a
            }

            container.register(CircularB.self) { resolver in
                let b = ConcreteCircularB()
                b.a = try? resolver.resolve(CircularA.self) // This creates a cycle
                return b
            }

            do {
                _ = try container.resolve(CircularA.self)
                // Note: This may or may not cause a cycle depending on optional resolution
                // The test is for demonstration purposes
            } catch let error as ContainerError {
                if case .circularDependency = error {
                    #expect(true)
                }
            }
        }

        @Test("No false positives for valid dependency chains")
        func testValidDependencyChain() async throws {
            let container = Container(name: "TestContainer")

            // Simple linear chain: UseCase → Service
            container.register(TestServiceProtocol.self) { _ in
                TestService(id: "chain-service")
            }

            container.register(TestUseCaseProtocol.self) { resolver in
                let service = try resolver.resolve(TestServiceProtocol.self)
                return TestUseCase(service: service, repository: TestRepository())
            }

            let useCase = try container.resolve(TestUseCaseProtocol.self)

            #expect(useCase.execute().contains("chain-service"))
        }
    }

    // MARK: - Memory Management Tests

    @Suite("Memory Management")
    @MainActor struct MemoryManagementTests {

        @Test("Cleanup clears cached instances")
        func testCleanup() async throws {
            let container = Container(name: "TestContainer")

            try container.register(TestServiceProtocol.self, scope: .cached) { _ in
                TestService(id: "before-cleanup")
            }

            let instance1 = try container.resolve(TestServiceProtocol.self)
            #expect(instance1.id == "before-cleanup")

            // Cleanup
            container.cleanup()

            // Re-register with different factory
            try container.register(TestServiceProtocol.self, scope: .cached) { _ in
                TestService(id: "after-cleanup")
            }

            let instance2 = try container.resolve(TestServiceProtocol.self)
            #expect(instance2.id == "after-cleanup")
        }

        @Test("Multiple cleanups are safe")
        func testMultipleCleanups() async throws {
            let container = Container(name: "TestContainer")

            container.register(TestServiceProtocol.self) { _ in TestService() }

            // Multiple cleanups should not crash
            container.cleanup()
            container.cleanup()
            container.cleanup()

            #expect(true)
        }
    }

    // MARK: - Container Hierarchy Tests

    @Suite("Container Hierarchy")
    @MainActor struct HierarchyTests {

        @Test("Child can resolve from parent")
        func testChildResolvesFromParent() async throws {
            let parent = Container(name: "ParentContainer")

            parent.register(TestServiceProtocol.self) { _ in
                TestService(id: "from-parent")
            }

            let child = Container(name: "ChildContainer", parent: parent)

            // Child should be able to resolve parent's registration
            let service = try child.resolve(TestServiceProtocol.self)

            #expect(service.id == "from-parent")
        }

        @Test("Child can override parent registration")
        func testChildOverridesParent() async throws {
            let parent = Container(name: "ParentContainer")

            parent.register(TestServiceProtocol.self) { _ in
                TestService(id: "from-parent")
            }

            let child = Container(name: "ChildContainer", parent: parent)

            child.register(TestServiceProtocol.self) { _ in
                TestService(id: "from-child")
            }

            let serviceFromChild = try child.resolve(TestServiceProtocol.self)

            #expect(serviceFromChild.id == "from-child")
        }
    }

    // MARK: - Thread Safety Tests

    @Suite("Thread Safety")
    @MainActor struct ThreadSafetyTests {

        @Test("Concurrent resolutions are safe")
        func testConcurrentResolutions() async throws {
            let container = Container(name: "TestContainer")

            try container.register(TestServiceProtocol.self, scope: .cached) { _ in
                TestService(id: "concurrent-test")
            }

            // Resolve multiple times concurrently
            try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<20 {
                    group.addTask {
                        let service = try await container.resolve(TestServiceProtocol.self)
                        return service.id
                    }
                }

                var ids: Set<String> = []
                for try await id in group {
                    ids.insert(id)
                }

                // All should have the same ID (cached scope)
                #expect(ids.count == 1, "All resolutions should return same cached instance")
            }
        }

        @Test("Concurrent resolutions with dependencies do not false-detect circular dependency")
        func testConcurrentResolutionsWithDependencies() async throws {
            let container = Container(name: "ThreadSafetyContainer")

            // Register a dependency chain: UseCase → Service + Repository
            try container.register(TestServiceProtocol.self, scope: .transient) { _ in
                TestService(id: "thread-safe-service")
            }

            try container.register(TestRepositoryProtocol.self, scope: .transient) { _ in
                TestRepository(data: "thread-safe-repo")
            }

            try container.register(TestUseCaseProtocol.self, scope: .transient) { resolver in
                let service = try resolver.resolve(TestServiceProtocol.self)
                let repository = try resolver.resolve(TestRepositoryProtocol.self)
                return TestUseCase(service: service, repository: repository)
            }

            // Resolve the same dependency chain from 50 concurrent tasks.
            // With a shared ResolutionContext stack, concurrent pushes of the same
            // type name cause false circular dependency detection.
            try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<50 {
                    group.addTask {
                        let useCase = try await container.resolve(TestUseCaseProtocol.self)
                        return useCase.execute()
                    }
                }

                var results: [String] = []
                for try await result in group {
                    results.append(result)
                }

                #expect(results.count == 50, "All 50 concurrent resolutions should succeed")
                for result in results {
                    #expect(result == "thread-safe-service-thread-safe-repo")
                }
            }
        }
    }

    // MARK: - Edge Cases

    @Suite("Edge Cases")
    @MainActor struct EdgeCaseTests {

        @Test("Re-registering replaces existing registration")
        func testReRegistration() async throws {
            let container = Container(name: "TestContainer")

            container.register(TestServiceProtocol.self) { _ in
                TestService(id: "first")
            }

            let first = try container.resolve(TestServiceProtocol.self)
            #expect(first.id == "first")

            // Re-register
            container.register(TestServiceProtocol.self) { _ in
                TestService(id: "second")
            }

            let second = try container.resolve(TestServiceProtocol.self)
            #expect(second.id == "second")
        }

        @Test("Empty container name is valid")
        func testEmptyContainerName() async {
            let container = Container(name: "")

            #expect(container.name.isEmpty)
        }

        @Test("Container with nil parent")
        func testNilParent() async {
            let container = Container(name: "Orphan", parent: nil)

            #expect(container.name == "Orphan")
        }
    }
}

// MARK: - Property Wrapper Tests

@Suite("@Resolve Property Wrapper", .serialized)
@MainActor
struct ResolvePropertyWrapperTests {

    @Test("@Resolve resolves registered service")
    func testResolvePropertyWrapper() async throws {
        let previousDefault = Container.default
        defer { Container.default = previousDefault }

        let container = Container(name: "PropertyWrapperTest")
        Container.default = container

        try container.register(TestServiceProtocol.self, scope: .cached) { _ in
            TestService(id: "property-wrapper-test")
        }

        @MainActor struct TestViewModel {
            @Resolve var service: TestServiceProtocol
        }

        var viewModel = TestViewModel()

        #expect(viewModel.service.id == "property-wrapper-test")
    }

    @Test("@ResolveOptional returns nil when not registered")
    func testResolveOptionalPropertyWrapper() async {
        let previousDefault = Container.default
        defer { Container.default = previousDefault }

        let container = Container(name: "OptionalPropertyWrapperTest")
        Container.default = container

        @MainActor struct TestViewModel {
            @ResolveOptional var service: TestServiceProtocol?
        }

        var viewModel = TestViewModel()

        #expect(viewModel.service == nil)
    }

    @Test("@ResolveOptional returns value when registered")
    func testResolveOptionalPropertyWrapperWithValue() async throws {
        let previousDefault = Container.default
        defer { Container.default = previousDefault }

        let container = Container(name: "OptionalPropertyWrapperWithValueTest")
        Container.default = container

        container.register(TestServiceProtocol.self) { _ in
            TestService(id: "optional-service")
        }

        @MainActor struct TestViewModel {
            @ResolveOptional var service: TestServiceProtocol?
        }

        var viewModel = TestViewModel()

        #expect(viewModel.service?.id == "optional-service")
    }
}

// MARK: - Assembly Resolution Tests

@Suite("Assembly Resolution", .serialized)
@MainActor
struct AssemblyResolutionTests {}
