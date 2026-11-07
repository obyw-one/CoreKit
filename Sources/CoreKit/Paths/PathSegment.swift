//
//  PathSegment.swift
//  CoreKit
//

import Foundation

// MARK: - PathSegment

/// One validated component of a ``VirtualPath``: a NAME, never a path.
///
/// A segment cannot be built unvalidated, which is the whole containment
/// story at the type level (BR-RP-04): there is no `PathSegment` that holds a
/// separator, a `..`, or an empty string, so a parameterised owner — a flow
/// whose id is a folder name — cannot climb out of its node by being handed a
/// hostile id. The id fails at the one `PathSegment(id)` the owner writes, with
/// the exact reason, before any URL exists.
///
/// The rules are the intersection of what the platforms and stores the fleet
/// runs on can carry, so one segment is safe on a POSIX disk, a Windows disk
/// and an S3-compatible object key alike (the "agnostic representation"):
///
/// - non-empty, not `.` or `..`;
/// - no `/` or `\`;
/// - no control character and none of `<>:"|?*`;
/// - no leading or trailing whitespace and no trailing dot;
/// - at most ``maximumByteCount`` UTF-8 bytes.
///
/// A leading dot is allowed (`.tests`, `.manifest.json` are real names).
public struct PathSegment: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {

    /// The longest segment a filesystem name can carry, in UTF-8 bytes.
    public static let maximumByteCount = 255

    /// The validated name.
    public let rawValue: String

    // MARK: - Init

    /// Validates `raw` and wraps it.
    public init(_ raw: String) throws(VirtualPathError) {
        try Self.validate(raw)
        rawValue = raw
    }

    /// A segment written as a source literal — the owner's declared name.
    ///
    /// A literal is a constant in the source, so an invalid one is a
    /// programming error found the first time the declaration is touched, by
    /// any test that resolves the owner — it traps with the reason rather than
    /// carrying a bad name into a path. Names that come from data (an id, a
    /// branch, a hostname) go through the throwing ``init(_:)`` or ``slug(from:)``.
    ///
    /// Swift reads a call spelled with a literal argument, `PathSegment("x")`,
    /// as a coercion to this initialiser (SE-0213) — so a literal that is not a
    /// valid name traps instead of throwing. Pass a variable to get the throw.
    public init(stringLiteral value: String) {
        do {
            try Self.validate(value)
        } catch {
            preconditionFailure("PathSegment literal '\(value)' is invalid: \(error)")
        }
        rawValue = value
    }

    /// Turns arbitrary text — a branch name, a hostname, a title — into a
    /// segment by replacing every character a segment cannot carry with `-`,
    /// collapsing runs and trimming the ends. For GROUPING names where the
    /// readable form matters and uniqueness is carried elsewhere (a branch
    /// slug beside a correlation id), never for an identity.
    ///
    /// Throws when nothing survives (an empty or all-forbidden input) or when
    /// the result is itself a traversal name.
    public static func slug(from text: String) throws(VirtualPathError) -> PathSegment {
        var out = ""
        var previousWasDash = false
        for scalar in text.unicodeScalars {
            let keep = !forbidden(scalar) && !CharacterSet.whitespacesAndNewlines.contains(scalar)
            if keep {
                out.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                out.append(dash)
                previousWasDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: String(dash) + PathVocabulary.currentComponent))
        return try PathSegment(trimmed)
    }

    // MARK: - CustomStringConvertible

    public var description: String { rawValue }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        do {
            try Self.validate(raw)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not a path segment: \(error)")
        }
        rawValue = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // MARK: - Validation

    private static let dash: Character = "-"
    private static let reservedScalars = Set("<>:\"|?*".unicodeScalars)

    private static func forbidden(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
            || reservedScalars.contains(scalar)
            || PathSeparator.allCases.contains { $0.rawValue.unicodeScalars.contains(scalar) }
    }

    private static func validate(_ raw: String) throws(VirtualPathError) {
        guard !raw.isEmpty else { throw .emptySegment }
        guard raw != PathVocabulary.currentComponent, raw != PathVocabulary.parentComponent else {
            throw .traversalSegment(raw)
        }
        let byteCount = raw.utf8.count
        guard byteCount <= maximumByteCount else {
            throw .segmentTooLong(length: byteCount, limit: maximumByteCount)
        }
        for scalar in raw.unicodeScalars {
            if PathSeparator.allCases.contains(where: { $0.rawValue.unicodeScalars.contains(scalar) }) {
                throw .separatorInSegment(raw)
            }
            if forbidden(scalar) {
                throw .forbiddenCharacter(segment: raw, scalar: scalar.value)
            }
        }
        if raw.unicodeScalars.first.map(CharacterSet.whitespacesAndNewlines.contains) == true
            || raw.unicodeScalars.last.map(CharacterSet.whitespacesAndNewlines.contains) == true
            || raw.hasSuffix(PathVocabulary.currentComponent) {
            throw .unstableBoundary(raw)
        }
    }
}
