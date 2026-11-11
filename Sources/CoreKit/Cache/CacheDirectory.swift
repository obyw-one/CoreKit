//
//  CacheDirectory.swift
//  CoreKit
//

import Foundation

// MARK: - CacheDirectory

/// The shared directory that default-located caches live in, owned in the
/// virtual tree like any other resource.
///
/// A `CacheRepository` that is given no directory resolves it through the
/// injected ``PathResolving``: the layer's root, then this owner's node. A host
/// that wants caches somewhere else moves the `cache` node (a `nodeRoots`
/// entry in its settings) — no cache declaration changes. The host must add
/// this owner to the tree (`VirtualPathRegistry([CacheDirectory.self, ...])`);
/// an unregistered one is refused by name.
public struct CacheDirectory: VirtualPathOwning {

    /// The scope-kind node default-located caches sit under.
    public static let node = VirtualNode("cache")

    public static let placement = VirtualPlacement(node: node, name: "caches")

    public init() {}

    /// The node itself: every default-located cache shares the directory, as
    /// they always shared the documents folder (their files stay prefixed by
    /// the cache name).
    public func location() throws(VirtualPathError) -> VirtualPath { .empty }
}

// MARK: - CacheLocationError

/// A cache that was given no directory could not find one. Thrown by the cache's
/// operations — never swallowed into a fallback folder.
public enum CacheLocationError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {

    /// No ``PathResolving`` is registered in the dependency container.
    case noPathLayerRegistered(cache: String)

    /// The registered layer refused: its reason is the path layer's own.
    case unresolvable(cache: String, reason: String)

    public var description: String {
        switch self {
        case .noPathLayerRegistered(let cache):
            "Cache '\(cache)' has no directory: none was passed and no PathResolving is registered in DI. "
                + "Pass baseDirectory:, pass the layer with `in:`, or register DIAssemblyResourcePaths."
        case .unresolvable(let cache, let reason):
            "Cache '\(cache)' has no directory: the path layer could not resolve CacheDirectory — \(reason)"
        }
    }

    public var errorDescription: String? { description }
}
