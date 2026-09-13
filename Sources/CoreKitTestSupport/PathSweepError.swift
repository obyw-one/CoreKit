import Foundation

// MARK: - PathSweepError

/// Thrown by any sentinel-guarded sweep (`TestScratch.removeScratchDir`,
/// `TestSandbox.sweep`) when the target does not carry the mint that
/// authorized the removal. A sweep that could reach live data must refuse,
/// loudly (spec one-path-resolution-ssot BR-PATH-03).
public enum PathSweepError: Error, Equatable, Sendable {
    /// `path` is not under the `.tests`/`.test-runs/<mint>` sub-tree that
    /// authorized the sweep.
    case outsideSandbox(path: String)
}
