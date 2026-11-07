//
//  Distribution.swift
//  CoreKit
//
//  Promoted from WabiSabi's `Core/Abstracts/Data Layer/Models/Env/Distribution.swift`.
//

import Foundation

// MARK: - Distribution

/// How this build was compiled — the only distinction local feature-flag
/// defaults act on. Debug affordances exist in `.debug`; the release shape
/// exists in `.release`. Which BACKEND a build talks to is a different axis
/// (a host's environment name) and is not decided here.
///
/// There is deliberately no TestFlight case: the only runtime signal for it is
/// the sandbox receipt, which App Store review installs carry too, so a
/// TestFlight-only behaviour is a behaviour Apple's reviewers get.
public enum Distribution: String, Sendable, CaseIterable {
    case debug
    case release

    /// The distribution of the running build, from the compiler's `DEBUG`
    /// condition in THIS package. SwiftPM builds a dependency in the
    /// consumer's configuration, so a debug app gets `.debug`.
    public static var current: Self {
        #if DEBUG
            .debug
        #else
            .release
        #endif
    }

    public static var isDebugBuild: Bool { current == .debug }
}
