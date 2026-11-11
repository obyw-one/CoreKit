//
//  TestRunRoot.swift
//  CoreKit
//

import Foundation

// MARK: - TestRunRoot

/// The run-scoped root a test layer is built over (BR-RP-03, BR-RP-14):
///
///     <base>/.tests/<branch-slug>/<correlation-id>/<target>/
///
/// Several sub-agents testing one target on one device would race a shared
/// `.tests/<target>/`, so each run gets its own subtree keyed by the DISPATCH
/// CORRELATION ID — assigned at dispatch, unique, and stable across a rebase or
/// a branch switch. The branch slug is only a readable grouping segment, never
/// the uniqueness key: a git-ref key would orphan the folder the moment the
/// branch is renamed. Results are not consolidated by reading this folder —
/// it isolates FIXTURES and scratch only.
///
/// The type validates every component, so a hostile branch name or id cannot
/// climb out of `.tests/`, and ``reference`` prints the exact branch and
/// correlation id a reaper keys on.
public struct TestRunRoot: Sendable, Equatable {

    /// The directory under `base` that holds every test run.
    public static let directoryName: PathSegment = ".tests"

    public let base: URL
    public let branch: PathSegment
    public let correlationID: PathSegment
    public let target: PathSegment

    /// - Parameters:
    ///   - base: the root the test tree sits under (for shikki, its home).
    ///   - branch: the branch name; slugged, as it is only a grouping segment.
    ///   - correlationID: the dispatch correlation id; validated, never slugged,
    ///     because it is the identity a reaper matches against @db state.
    ///   - target: the test target (or scope) the run exercises; slugged.
    public init(
        base: URL, branch: String, correlationID: String, target: String
    ) throws(VirtualPathError) {
        guard base.isFileURL else { throw .rootNotFileURL(base.absoluteString) }
        self.base = base.standardizedFileURL
        self.branch = try .slug(from: branch)
        self.correlationID = try PathSegment(correlationID)
        self.target = try .slug(from: target)
    }

    /// The run's directory. Not created — the writer creates it.
    public var url: URL {
        VirtualPath(Self.directoryName, branch, correlationID, target).fileURL(under: base)
    }

    /// `<branch>/<correlation-id>` — what is printed so the run's tree is easy
    /// to find and easy to reap, and what a reaper looks the run up by.
    public var reference: String {
        VirtualPath(branch, correlationID).rendered()
    }
}
