import CoreKit
import CoreKitTestSupport
import Foundation
import Testing

// MARK: - Fixtures

private let sample = ConformancePayload(id: 1, name: "sample")

private struct Sandbox {
    let scratch = TestScratch.forPackage()
    let root: URL

    init() throws {
        root = try scratch.makeScratchDir(scope: "cache-default-location")
    }

    func sweep() { try? scratch.removeScratchDir(root) }

    func layer(registering owners: [any VirtualPathOwning.Type] = [CacheDirectory.self],
               nodeRoots: [VirtualNode: URL] = [:]) throws -> PathLayer {
        try PathLayer(root: root, nodeRoots: nodeRoots, registry: VirtualPathRegistry(owners))
    }
}

// MARK: - CacheDefaultLocationTests

@Suite("CacheRepository default location — the path layer owns it, never the documents folder")
struct CacheDefaultLocationTests {

    @Test("a cache given a path layer lives under its root, in the cache node")
    func resolvesThroughTheLayer() throws {
        let box = try Sandbox()
        defer { box.sweep() }
        let cache = CacheRepository<ConformancePayload>("located", invalidateTime: .never, in: try box.layer())
        try cache.save("a", data: sample)
        let expected = box.root.appendingPathComponent("cache", isDirectory: true).appendingPathComponent("located-a.cache")
        #expect(FileManager.default.fileExists(atPath: expected.path))
        #expect(try cache.get("a") == sample)
    }

    @Test("moving the cache node moves every default-located cache with no declaration changing")
    func nodeCanBeRelocated() throws {
        let box = try Sandbox()
        defer { box.sweep() }
        let elsewhere = box.root.appendingPathComponent("elsewhere", isDirectory: true)
        let cache = CacheRepository<ConformancePayload>(
            "moved", invalidateTime: .never, in: try box.layer(nodeRoots: [CacheDirectory.node: elsewhere]))
        try cache.save("a", data: sample)
        #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("moved-a.cache").path))
    }

    @Test("a layer that does not own CacheDirectory is a named error on every operation, with no other folder tried")
    func unregisteredIsNamed() throws {
        let box = try Sandbox()
        defer { box.sweep() }
        let cache = CacheRepository<ConformancePayload>("refused", in: try box.layer(registering: []))
        func isUnresolvable(_ error: any Error?) -> Bool {
            guard case .unresolvable(let name, let reason)? = error as? CacheLocationError else { return false }
            return name == "refused" && reason.contains("CacheDirectory")
        }
        #expect(isUnresolvable(#expect(throws: CacheLocationError.self) { try cache.save("a", data: sample) }))
        #expect(isUnresolvable(#expect(throws: CacheLocationError.self) { _ = try cache.get("a") }))
        #expect(isUnresolvable(#expect(throws: CacheLocationError.self) { try cache.delete("a") }))
        #expect(isUnresolvable(#expect(throws: CacheLocationError.self) { _ = try cache.list() }))
        #expect(!cache.exists("a"))
        #expect(cache.ioProfile == .atomic)
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.root.path).isEmpty, "something was created anyway")
    }

    @Test("an explicit baseDirectory behaves exactly as it always did")
    func explicitDirectoryUnchanged() throws {
        let box = try Sandbox()
        defer { box.sweep() }
        let cache = CacheRepository<ConformancePayload>("explicit", invalidateTime: .never, baseDirectory: box.root)
        try cache.save("a", data: sample)
        #expect(FileManager.default.fileExists(atPath: box.root.appendingPathComponent("explicit-a.cache").path))
    }

    @Test("CacheDirectory is the cache node itself")
    func ownerShape() throws {
        #expect(CacheDirectory.placement.node == CacheDirectory.node)
        #expect(try CacheDirectory().location().isEmpty)
        #expect(CacheLocationError.noPathLayerRegistered(cache: "x").description.contains("DIAssemblyResourcePaths"))
    }
}

// Nested under the serialized `@Resolve` suite: the deprecated nil path reads
// `Container.default`, and these swap it (see DIConfigureOnceTests for why).
extension ResolvePropertyWrapperTests {
    @Suite("CacheRepository nil directory — resolved through DI", .serialized)
    struct CacheDefaultLocationDITests {

        @Test("with no path layer registered the deprecated nil path throws a named error and writes nowhere")
        @available(*, deprecated, message: "exercises the deprecated initialiser on purpose")
        func noLayerIsNamed() throws {
            let previous = Container.default
            defer { Container.default = previous }
            Container.default = Container(name: "empty")

            let name = "nolayer-\(UUID().uuidString.prefix(8))"
            let cache = CacheRepository<ConformancePayload>(name)
            let error = #expect(throws: CacheLocationError.self) { try cache.save("a", data: sample) }
            #expect(error == .noPathLayerRegistered(cache: name))
            #expect(throws: CacheLocationError.self) { _ = try cache.get("a") }
            #expect(throws: CacheLocationError.self) { _ = try cache.list() }
            #expect(!cache.exists("a"))

            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            for directory in documents {
                #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name)-a.cache").path),
                        "the documents folder was used as a fallback")
            }
        }

        @Test("with a path layer registered in DI the deprecated nil path resolves through it")
        @available(*, deprecated, message: "exercises the deprecated initialiser on purpose")
        func layerFromDI() throws {
            let box = try Sandbox()
            defer { box.sweep() }
            let previous = Container.default
            defer { Container.default = previous }
            let container = Container(name: "with-layer")
            DIAssemblyResourcePaths(layer: try box.layer()).assemble(container: container, environment: .production)
            Container.default = container

            let cache = CacheRepository<ConformancePayload>("via-di", invalidateTime: .never)
            try cache.save("a", data: sample)
            #expect(FileManager.default.fileExists(
                atPath: box.root.appendingPathComponent("cache", isDirectory: true).appendingPathComponent("via-di-a.cache").path))
            #expect(try cache.get("a") == sample)
        }

        @Test("a nil URL? passed explicitly takes the same DI path")
        @available(*, deprecated, message: "exercises the deprecated initialiser on purpose")
        func explicitNil() {
            let previous = Container.default
            defer { Container.default = previous }
            Container.default = Container(name: "empty")
            let missing: URL? = nil
            let cache = CacheRepository<ConformancePayload>("nil-url", baseDirectory: missing)
            #expect(throws: CacheLocationError.self) { try cache.save("a", data: sample) }
        }
    }
}
