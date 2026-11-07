//
//  PathSeparator.swift
//  CoreKit
//
//  The separator vocabulary of the fleet, in the layer every kit can reach.
//
//  A path that touches the disk is a `URL` built component by component and
//  needs no separator at all. These tokens are for the places a path is
//  VALIDATED, COMPARED, SPLIT or RENDERED to a wire form — an object-store
//  key, a git pathspec, a log line — and the rule they exist for is that a
//  separator is spelled once, here, and never typed inside a string at a call
//  site.
//

import Foundation

// MARK: - PathSeparator

/// The separators a path is ever joined with, compared against, or split on.
///
/// Both are named because both are needed: ``native`` is the OS's, and a
/// consumer that must match a tool's output picks the one that tool emits
/// regardless of platform — git porcelain and every object store speak
/// ``posix`` on Windows too.
public enum PathSeparator: String, Sendable, CaseIterable, Equatable {

    /// The POSIX separator — and what git and object stores use on every platform.
    case posix = "/"

    /// The Windows separator.
    case windows = "\\"

    /// The separator for the OS this binary is compiled for.
    public static var native: PathSeparator {
        #if os(Windows)
            .windows
        #else
            .posix
        #endif
    }

    /// The separator as a `Character`, for `split(separator:)`.
    public var character: Character {
        // Both raw values are one grapheme by construction (pinned by a test),
        // so this cannot trap — and there is no second spelling of the slash.
        Character(rawValue)
    }
}

// MARK: - PathVocabulary

/// The path tokens the fleet validates against — named here rather than
/// spelled at each guard.
public enum PathVocabulary {

    /// The OS separator, as a string. The short name call sites read.
    public static var separator: String { PathSeparator.native.rawValue }

    /// The POSIX separator, for a check that must not vary by platform: an
    /// object key, a manifest-declared relative path, a sandbox rule. These are
    /// wire values, so they are POSIX wherever the binary runs.
    public static let wireSeparator: String = PathSeparator.posix.rawValue

    /// The POSIX separator as a `Character`, for `split(separator:)` on a wire value.
    public static let wireSeparatorCharacter: Character = PathSeparator.posix.character

    /// The parent-traversal component every validator here rejects.
    public static let parentComponent = ".."

    /// The current-directory component, and the prefix a hidden name carries.
    public static let currentComponent = "."

    /// The filesystem root a walk terminates at, so a loop guard does not spell it.
    /// POSIX-rooted by construction, like ``wireSeparator``.
    public static let filesystemRoot: String = PathSeparator.posix.rawValue

    /// The home-directory shorthand. A settings value that starts with it has
    /// not been expanded, and a root must never be taken from one unexpanded:
    /// it would silently become a directory literally named after the tilde,
    /// relative to wherever the process happens to be.
    public static let homeShorthand = "~"
}
