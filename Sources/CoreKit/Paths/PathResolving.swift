//
//  PathResolving.swift
//  CoreKit
//

import Foundation

// MARK: - PathContainment

/// Containment is a CHECK, not a naming convention (BR-RP-04).
///
/// ``PathSegment`` makes a climbing segment unrepresentable; this is the
/// second line for what a segment cannot see — a symlink inside a node that
/// points out of it, a URL that arrived from somewhere else (a sweep about to
/// delete, a user-supplied path). Both sides are standardised AND symlink-resolved
/// before they are compared, so `/tmp` vs `/private/tmp` and a link into live
/// data cannot make an outside path look inside.
///
/// Resolution works on paths that do not exist yet (a resolver resolves, the
/// writer creates): the deepest component that DOES exist is resolved, and the
/// rest is appended unchanged. A dangling symlink on that walk cannot be
/// resolved, so containment cannot be proved and the answer is "no".
public enum PathContainment {

    /// `true` when `url` is `base` or lies below it.
    public static func isContained(_ url: URL, in base: URL) -> Bool {
        guard let target = canonical(url), let boundary = canonical(base) else { return false }
        return target.starts(with: boundary)
    }

    /// Throws ``VirtualPathError/escapesRoot(path:root:)`` unless ``isContained(_:in:)``.
    public static func require(_ url: URL, in base: URL) throws(VirtualPathError) {
        guard isContained(url, in: base) else {
            throw .escapesRoot(path: url.path, root: base.path)
        }
    }

    /// The path components with the existing prefix symlink-resolved; `nil`
    /// when a dangling symlink makes the real location unknowable.
    private static func canonical(_ url: URL) -> [String]? {
        let fileManager = FileManager.default
        var existing = url.standardizedFileURL
        var pending: [String] = []
        // `attributesOfItem` does not follow a final symlink, so a link is
        // "existing" here even when its target is not.
        while (try? fileManager.attributesOfItem(atPath: existing.path)) == nil, existing.pathComponents.count > 1 {
            pending.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        // Seen by lstat but not by stat: a dangling symlink.
        guard fileManager.fileExists(atPath: existing.path) else { return nil }
        return existing.resolvingSymlinksInPath().standardizedFileURL.pathComponents + pending
    }
}

// MARK: - PathResolving

/// Turns an owner and the injected root into a resolved location (BR-RP-01).
///
/// ONE protocol with two DI implementations — prod and test — that are the
/// same type composed over different roots: nothing else differs, so a test
/// exercises the production composition (BR-RP-03). Resolution is RESOLVE-ONLY:
/// nothing is created, no fallback is tried, a failure is thrown. The WRITER
/// creates the directory it writes into.
///
/// An owner resolves only if its kind was added to the tree
/// (``VirtualPathOwnerable``): an unregistered owner is a second, invisible
/// tree, and is refused with the type's name.
public protocol PathResolving: VirtualPathOwnerable {

    /// The injected root: an absolute file URL. Prod and test differ only by it.
    var root: URL { get }

    /// The directory a node is served from: `root` plus the node's components,
    /// unless the layer was told to serve that node from elsewhere (a root
    /// that is a setting, BR-RP-05).
    func base(of node: VirtualNode) -> URL

    /// The owner's location as components below the ROOT — agnostic: no root,
    /// no OS. The single source every other form is rendered from.
    func virtualPath<Owner: VirtualPathOwning>(for owner: Owner) throws(VirtualPathError) -> VirtualPath

    /// The owner's local file location, contained in its node's base.
    func url<Owner: VirtualPathOwning>(for owner: Owner) throws(VirtualPathError) -> URL

    /// The owner's object-store address: the SAME components, under `bucket`,
    /// with `nodeID` in the key (BR-RP-07, BR-RP-11).
    func address<Owner: VirtualPathOwning>(
        for owner: Owner, bucket: BucketName, nodeID: NodeID
    ) throws(VirtualPathError) -> ResourceAddress
}

extension PathResolving {

    public func virtualPath<Owner: VirtualPathOwning>(for owner: Owner) throws(VirtualPathError) -> VirtualPath {
        try requireRegistered(Owner.self)
        return Owner.placement.node.path.appending(try owner.location())
    }

    public func url<Owner: VirtualPathOwning>(for owner: Owner) throws(VirtualPathError) -> URL {
        try requireRegistered(Owner.self)
        let nodeBase = base(of: Owner.placement.node)
        let resolved = try owner.location().fileURL(under: nodeBase)
        try PathContainment.require(resolved, in: nodeBase)
        return resolved
    }

    public func address<Owner: VirtualPathOwning>(
        for owner: Owner, bucket: BucketName, nodeID: NodeID
    ) throws(VirtualPathError) -> ResourceAddress {
        ResourceAddress(bucket: bucket, node: nodeID, path: try virtualPath(for: owner))
    }

    private func requireRegistered(_ owner: any VirtualPathOwning.Type) throws(VirtualPathError) {
        guard registry.contains(owner) else {
            throw .unregisteredOwner(String(reflecting: owner))
        }
    }
}

// MARK: - PathLayerConfiguration

/// The settings-facing shape of a layer's roots: plain strings a host decodes
/// from its settings file and hands to ``PathLayer/init(configuration:registry:)``.
///
/// Strings, not URLs, on purpose: `URL(fileURLWithPath:)` quietly makes a
/// relative path absolute against the process's working directory, which is
/// exactly how a mis-set root becomes "wherever I was launched from". The
/// layer validates the STRING before any URL exists.
public struct PathLayerConfiguration: Codable, Sendable, Equatable {

    /// The root: an absolute path. CoreKit holds no default — the host injects
    /// the one its install defined (BR-RP-03).
    public var root: String

    /// Per-node overrides: a node's rendered virtual path (`flows`,
    /// `state/ai-routing`) to the absolute directory it is served from.
    public var nodeRoots: [String: String]

    public init(root: String, nodeRoots: [String: String] = [:]) {
        self.root = root
        self.nodeRoots = nodeRoots
    }
}

// MARK: - PathLayer

/// The one ``PathResolving`` implementation: a value over an injected root.
///
/// A value type with no mutable state, so it is `Sendable` without caveats and
/// can be copied into any task — resolution has nothing to race on. Prod
/// builds it from the host's settings; a test builds the SAME type over a
/// run-scoped root (see ``TestRunRoot``).
public struct PathLayer: PathResolving {

    public let root: URL
    public let registry: VirtualPathRegistry
    private let nodeRoots: [VirtualNode: URL]

    /// - Parameters:
    ///   - root: the injected root; must be a file URL.
    ///   - nodeRoots: nodes served from somewhere other than below `root`.
    ///   - registry: the owner kinds in the tree.
    public init(
        root: URL,
        nodeRoots: [VirtualNode: URL] = [:],
        registry: VirtualPathRegistry = .empty
    ) throws(VirtualPathError) {
        guard root.isFileURL else { throw .rootNotFileURL(root.absoluteString) }
        for url in nodeRoots.values where !url.isFileURL {
            throw .rootNotFileURL(url.absoluteString)
        }
        self.root = root.standardizedFileURL
        self.nodeRoots = nodeRoots.mapValues(\.standardizedFileURL)
        self.registry = registry
    }

    /// Builds the layer from settings strings, refusing a root that is blank,
    /// an unexpanded home shorthand, or relative — the three ways a root
    /// silently drifts to the working directory.
    public init(
        configuration: PathLayerConfiguration,
        registry: VirtualPathRegistry = .empty
    ) throws(VirtualPathError) {
        var overrides: [VirtualNode: URL] = [:]
        for (key, raw) in configuration.nodeRoots {
            overrides[VirtualNode(path: try VirtualPath(parsing: key))] = try Self.absoluteDirectory(raw)
        }
        try self.init(
            root: try Self.absoluteDirectory(configuration.root),
            nodeRoots: overrides,
            registry: registry)
    }

    public func base(of node: VirtualNode) -> URL {
        nodeRoots[node] ?? node.path.fileURL(under: root)
    }

    /// A copy of this layer with `owners` added to the tree.
    public func registering(_ owners: [any VirtualPathOwning.Type]) throws(VirtualPathError) -> PathLayer {
        var next = registry
        for owner in owners {
            next = try next.adding(owner)
        }
        return try PathLayer(root: root, nodeRoots: nodeRoots, registry: next)
    }

    // MARK: - Root validation

    private static func absoluteDirectory(_ raw: String) throws(VirtualPathError) -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == raw, !trimmed.hasPrefix(PathVocabulary.homeShorthand),
            isAbsolute(trimmed)
        else { throw .rootNotAbsolute(raw) }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    private static func isAbsolute(_ path: String) -> Bool {
        if PathSeparator.allCases.contains(where: { path.hasPrefix($0.rawValue) }) { return true }
        // A Windows drive root: `X:` followed by a separator.
        let scalars = Array(path.unicodeScalars)
        guard scalars.count >= 3, scalars[0].properties.isAlphabetic, scalars[1] == drive else { return false }
        return PathSeparator.allCases.contains { $0.rawValue.unicodeScalars.contains(scalars[2]) }
    }

    private static let drive: Unicode.Scalar = ":"
}
