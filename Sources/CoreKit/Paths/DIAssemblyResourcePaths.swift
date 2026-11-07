//
//  DIAssemblyResourcePaths.swift
//  CoreKit
//

import Foundation

// MARK: - DIAssemblyResourcePaths

/// Registers the PRODUCTION path layer on the container.
///
/// Takes a layer already built (and therefore already validated) by the
/// composition root, which can handle a refusal; `assemble` cannot throw. The
/// root and the node overrides come from the host's settings — CoreKit holds no
/// default root, because a default is a second source of truth.
public struct DIAssemblyResourcePaths: DIAssembly {

    public let layer: PathLayer

    public init(layer: PathLayer) {
        self.layer = layer
    }

    public func assemble(container: Container, environment: DIEnvironment) {
        register(layer, in: container, assembly: "DIAssemblyResourcePaths")
    }
}

// MARK: - DIAssemblyResourcePathsMock

/// Registers the TEST path layer: the SAME ``PathLayer`` as production, over a
/// run-scoped ``TestRunRoot``. Nothing but the root differs, so a test that
/// resolves an owner exercises the production composition (BR-RP-03).
public struct DIAssemblyResourcePathsMock: DIAssembly {

    public let layer: PathLayer
    public let run: TestRunRoot

    /// - Parameters:
    ///   - run: the run-scoped root.
    ///   - nodeRoots: nodes served from elsewhere, if the test must model that.
    ///   - owners: the owner kinds to add to the tree.
    public init(
        run: TestRunRoot,
        nodeRoots: [VirtualNode: URL] = [:],
        owners: [any VirtualPathOwning.Type]
    ) throws(VirtualPathError) {
        self.run = run
        layer = try PathLayer(
            root: run.url, nodeRoots: nodeRoots, registry: VirtualPathRegistry(owners))
    }

    public func assemble(container: Container, environment: DIEnvironment) {
        register(layer, in: container, assembly: "DIAssemblyResourcePathsMock")
    }
}

// MARK: - Registration

private func register(_ layer: PathLayer, in container: Container, assembly: String) {
    // The scope is decided HERE, at the registration, never at a resolve site:
    // `.cached`, one instance per container. No `try!`: a refusal is named.
    do {
        try container.register((any PathResolving).self, scope: .cached) { _ in layer }
    } catch {
        fatalError(
            "\(assembly): the container refused `PathResolving` — \(error). Is the assembly listed twice?")
    }
}
