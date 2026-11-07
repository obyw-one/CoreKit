//
//  ResourceAddress.swift
//  CoreKit
//
//  The object-store form of a virtual path (BR-RP-07, BR-RP-11): the same
//  components an owner resolves to a local file, rendered as `bucket/key` with
//  a NODE ID in the key, so three machines working one spec never write the
//  same key.
//

import Foundation

// MARK: - NodeID

/// The identity of the machine (or worker) that wrote a resource.
///
/// Carried by EVERY ``ResourceAddress``: when several Macs run waves of one
/// spec and publish evidence to one store, identical logical keys must still
/// land on distinct physical keys, or the last writer silently erases the
/// others and a consolidation step reads a subset as the whole. Making the node
/// a required part of the address — rather than a convention callers remember —
/// is what rules that out.
public struct NodeID: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {

    /// The node id as a validated path segment.
    public let segment: PathSegment

    public init(_ raw: String) throws(VirtualPathError) {
        segment = try PathSegment(raw)
    }

    public init(_ segment: PathSegment) {
        self.segment = segment
    }

    public init(stringLiteral value: String) {
        segment = PathSegment(stringLiteral: value)
    }

    public var description: String { segment.description }

    public init(from decoder: Decoder) throws {
        segment = try decoder.singleValueContainer().decode(PathSegment.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(segment)
    }
}

// MARK: - BucketName

/// An object-store bucket name, validated to the rules every
/// S3-compatible store (Garage, MinIO, ...) accepts: 3 to 63 characters,
/// lowercase letters, digits, hyphens and dots, beginning and ending with a
/// letter or digit, with no two adjacent dots.
public struct BucketName: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {

    public static let lengthRange = 3...63

    public let rawValue: String

    public init(_ raw: String) throws(VirtualPathError) {
        guard Self.isValid(raw) else { throw .invalidBucketName(raw) }
        rawValue = raw
    }

    public init(stringLiteral value: String) {
        guard Self.isValid(value) else {
            preconditionFailure("BucketName literal '\(value)' is invalid")
        }
        rawValue = value
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard Self.isValid(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not a valid bucket name: '\(raw)'")
        }
        rawValue = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static let dot: Character = "."
    private static let hyphen: Character = "-"

    private static func isValid(_ raw: String) -> Bool {
        guard lengthRange.contains(raw.utf8.count) else { return false }
        let allowed: (Character) -> Bool = {
            ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == dot || $0 == hyphen
        }
        guard raw.allSatisfy(allowed),
              let first = raw.first, let last = raw.last,
            first != dot, first != hyphen, last != dot, last != hyphen
        else { return false }
        return !raw.contains(String(dot) + String(dot))
    }
}

// MARK: - ResourceAddress

/// `bucket` + `node` + virtual path: where a resource lives in an object
/// store, derived from the same components that locate it on a local disk.
///
/// The wire form is `bucket/<node>/<components...>`; the object KEY — what the
/// store sees below the bucket — is `<node>/<components...>`. Rendering uses
/// the POSIX separator (object keys are POSIX everywhere) and goes through
/// ``PathSeparator``, so no call site types a slash.
public struct ResourceAddress: Hashable, Sendable, Codable, CustomStringConvertible {

    public let bucket: BucketName
    public let node: NodeID
    /// The resource's location below the ROOT, scope-kind node included — the
    /// SAME components the owner resolves to on a local disk, which is what
    /// makes one owner addressable on either medium.
    public let path: VirtualPath

    public init(bucket: BucketName, node: NodeID, path: VirtualPath) {
        self.bucket = bucket
        self.node = node
        self.path = path
    }

    /// The object key's components: the node first, then the path.
    public var key: VirtualPath {
        VirtualPath(node.segment).appending(path)
    }

    /// The object key as a string — what is handed to the store below the bucket.
    public func renderedKey(separator: PathSeparator = .posix) -> String {
        key.rendered(separator: separator)
    }

    /// `bucket/key`.
    public func rendered(separator: PathSeparator = .posix) -> String {
        bucket.rawValue + separator.rawValue + renderedKey(separator: separator)
    }

    public var description: String { rendered() }

    /// Parses `bucket/node/components...` back into an address. The node is
    /// the second component, so an address with fewer than two is refused.
    public init(parsing wire: String, separator: PathSeparator = .posix) throws(VirtualPathError) {
        let parsed = try VirtualPath(parsing: wire, separator: separator)
        guard parsed.segments.count >= 2 else { throw .malformedWireForm(wire) }
        bucket = try BucketName(parsed.segments[0].rawValue)
        node = NodeID(parsed.segments[1])
        path = VirtualPath(Array(parsed.segments.dropFirst(2)))
    }
}
