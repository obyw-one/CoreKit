//
//  VirtualPath.swift
//  CoreKit
//

import Foundation

// MARK: - VirtualPath

/// A location in the virtual tree: an ordered list of ``PathSegment``s and
/// NOTHING else — no separator, no root, no OS.
///
/// This is the agnostic representation. It is not a
/// string with slashes in it; it is components, and every concrete form is
/// RENDERED from the components at the boundary that needs it:
///
/// - a local file: ``fileURL(under:)`` — a `URL` built component by component;
/// - an object key or a git pathspec: ``rendered(separator:)`` — the one place
///   a separator is typed, taken from ``PathSeparator``;
/// - back again: ``init(parsing:separator:)``.
///
/// Because every segment is validated, a `VirtualPath` cannot contain a
/// traversal: ``fileURL(under:)`` of any value is under its base by construction.
public struct VirtualPath: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {

    /// The components, outermost first.
    public let segments: [PathSegment]

    /// The path with no components: the node itself.
    public static let empty = VirtualPath([])

    // MARK: - Init

    public init(_ segments: [PathSegment]) {
        self.segments = segments
    }

    public init(_ segments: PathSegment...) {
        self.segments = segments
    }

    /// Parses a rendered path (an object key, a pathspec) back into components.
    /// Every component is validated, so `a/../b` and `a//b` are refused rather
    /// than normalised — a wire form is either well-formed or it is not a path.
    ///
    /// An empty string is the empty path.
    public init(parsing wire: String, separator: PathSeparator = .posix) throws(VirtualPathError) {
        guard !wire.isEmpty else {
            segments = []
            return
        }
        var parsed: [PathSegment] = []
        for component in wire.split(separator: separator.character, omittingEmptySubsequences: false) {
            guard !component.isEmpty else { throw .malformedWireForm(wire) }
            parsed.append(try PathSegment(String(component)))
        }
        segments = parsed
    }

    /// A path written as a source literal (`"state/ai-routing"`): the POSIX wire
    /// form of a declared location.
    ///
    /// A literal is a constant in the source, so an invalid one is a
    /// programming error — it traps with the reason, exactly as
    /// ``PathSegment/init(stringLiteral:)`` does, rather than carrying a bad
    /// path into the tree. Paths that come from data go through the throwing
    /// ``init(parsing:separator:)``.
    public init(stringLiteral value: String) {
        do {
            try self.init(parsing: value)
        } catch {
            preconditionFailure("VirtualPath literal '\(value)' is invalid: \(error)")
        }
    }

    // MARK: - Composition

    /// This path with one more component.
    public func appending(_ segment: PathSegment) -> VirtualPath {
        VirtualPath(segments + [segment])
    }

    /// This path followed by all of `other`.
    public func appending(_ other: VirtualPath) -> VirtualPath {
        VirtualPath(segments + other.segments)
    }

    /// `true` for the empty path.
    public var isEmpty: Bool { segments.isEmpty }

    /// The last component, `nil` for the empty path.
    public var last: PathSegment? { segments.last }

    /// The path without its last component; `nil` for the empty path.
    public var parent: VirtualPath? {
        isEmpty ? nil : VirtualPath(Array(segments.dropLast()))
    }

    /// `true` when `prefix`'s components are the leading components of this path.
    public func hasPrefix(_ prefix: VirtualPath) -> Bool {
        segments.starts(with: prefix.segments)
    }

    // MARK: - Rendering

    /// The path rendered with `separator` — the wire form. POSIX by default,
    /// because object keys, git pathspecs and manifests are POSIX on every
    /// platform; pass ``PathSeparator/native`` only to display a local path.
    public func rendered(separator: PathSeparator = .posix) -> String {
        segments.map(\.rawValue).joined(separator: separator.rawValue)
    }

    /// `base` followed by every component, as a `URL` built component by
    /// component. Resolve-only: nothing is created.
    public func fileURL(under base: URL) -> URL {
        segments.enumerated().reduce(base) { url, item in
            // Every segment but the last is a directory on the way; the last is the thing itself.
            url.appending(
                path: item.element.rawValue,
                directoryHint: item.offset == segments.count - 1 ? .notDirectory : .isDirectory)
        }
    }

    public var description: String { rendered() }

    // MARK: - Codable

    /// Encodes as an array of component strings.
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [PathSegment] = []
        while !container.isAtEnd {
            decoded.append(try container.decode(PathSegment.self))
        }
        segments = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for segment in segments {
            try container.encode(segment)
        }
    }
}
