//
//  VirtualPathError.swift
//  CoreKit
//

import Foundation

// MARK: - VirtualPathError

/// Every way the virtual path layer refuses. One typed enum for the whole
/// layer — segment validation, root validation, registration and resolution —
/// so a caller `throws(VirtualPathError)` end to end and a test can match the
/// exact reason instead of a message.
///
/// A refusal always carries its cause: the layer never answers a "best
/// effort" path, because a path that is almost right is a write into the
/// wrong place.
public enum VirtualPathError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {

    // MARK: Segments

    /// A segment was empty.
    case emptySegment
    /// A segment was `.` or `..` — traversal is never a name.
    case traversalSegment(String)
    /// A segment contained a path separator of either platform.
    case separatorInSegment(String)
    /// A segment contained a control character or one a supported platform or
    /// object store cannot carry (`<>:"|?*`).
    case forbiddenCharacter(segment: String, scalar: UInt32)
    /// A segment began or ended with whitespace, or ended with a dot — names a
    /// supported platform silently rewrites, which makes two names one.
    case unstableBoundary(String)
    /// A segment exceeded the length a filesystem name can carry.
    case segmentTooLong(length: Int, limit: Int)

    // MARK: Wire forms

    /// A rendered path could not be parsed back (empty input, empty component).
    case malformedWireForm(String)
    /// A bucket name did not satisfy the object-store naming rules.
    case invalidBucketName(String)

    // MARK: Roots

    /// A root was not an absolute file path (relative, blank, or an
    /// unexpanded home shorthand) — it would be taken from wherever the
    /// process happens to be.
    case rootNotAbsolute(String)
    /// A root URL was not a file URL.
    case rootNotFileURL(String)

    // MARK: Registration and resolution

    /// Two different owners claim the same node and name.
    case placementClash(placement: String, existing: String, incoming: String)
    /// An owner was asked to resolve but was never added to the tree.
    case unregisteredOwner(String)
    /// A resolved location is not under the root it was declared against.
    case escapesRoot(path: String, root: String)

    public var description: String {
        switch self {
        case .emptySegment:
            "VirtualPath: a segment is empty"
        case .traversalSegment(let segment):
            "VirtualPath: '\(segment)' is a traversal segment, not a name"
        case .separatorInSegment(let segment):
            "VirtualPath: segment '\(segment)' contains a path separator"
        case .forbiddenCharacter(let segment, let scalar):
            "VirtualPath: segment '\(segment)' contains U+\(String(scalar, radix: 16, uppercase: true)), which a supported platform or object store cannot carry"
        case .unstableBoundary(let segment):
            "VirtualPath: segment '\(segment)' begins or ends with whitespace, or ends with a dot"
        case .segmentTooLong(let length, let limit):
            "VirtualPath: a segment is \(length) bytes, the limit is \(limit)"
        case .malformedWireForm(let raw):
            "VirtualPath: '\(raw)' is not a well-formed path"
        case .invalidBucketName(let name):
            "ResourceAddress: '\(name)' is not a valid bucket name"
        case .rootNotAbsolute(let raw):
            "PathLayer: root '\(raw)' is not an absolute path"
        case .rootNotFileURL(let raw):
            "PathLayer: root '\(raw)' is not a file URL"
        case .placementClash(let placement, let existing, let incoming):
            "VirtualPathRegistry: \(incoming) claims \(placement), which \(existing) already owns"
        case .unregisteredOwner(let type):
            "PathLayer: \(type) was never added to the tree — register it in the VirtualPathRegistry"
        case .escapesRoot(let path, let root):
            "PathLayer: '\(path)' resolves outside '\(root)'"
        }
    }

    public var errorDescription: String? { description }
}
