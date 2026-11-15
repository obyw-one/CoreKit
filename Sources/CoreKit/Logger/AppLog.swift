//
//  AppLog.swift
//  CoreKit
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 02/04/2024.
//
//  Spec c8fa126c, W1. `AppLog` used to BE the logger: a `typealias AppLogger`
//  that resolved to `os.Logger` under `#if canImport(os)` and to
//  `Logging.Logger` otherwise. That is two code paths through one call site,
//  which BR-L-07 bans — the two backends disagreed on privacy, on level
//  mapping and on what a category is, and no test could see either.
//
//  It is now a THIN FACADE over the registered ``LoggingProviding``, kept for
//  one minor so no consumer breaks in the same release that moves them
//  (BR-L-05). New code resolves the protocol:
//  `try resolve((any LoggingProviding).self)`.
//

import Foundation

// MARK: - AppLog

/// App-wide logger namespace — named `AppLog` to avoid conflict with `os.Logger`
/// which is exported as `Logger` by `import os`.
///
/// Usage is unchanged: `AppLog.app.debug("message")`, `AppLog.cache.error("...")`.
/// What changed is underneath: every category now forwards to ``provider``.
///
/// **Setup:** a host sets the subsystem at launch and registers
/// ``CoreKitPlatformAssembly``, which installs the platform's provider here:
/// ```swift
/// AppLog.subsystem = "com.example.MyApp"
/// let container = DI.configure(for: .production, assemblies: [CoreKitPlatformAssembly()])
/// ```
public enum AppLog: Sendable {
    // MARK: - Configurable Subsystem

    /// The subsystem identifier used by all loggers.
    /// Must be set by the host app at launch (e.g., in `App.init()`).
    /// Defaults to the main bundle identifier if available, otherwise "CoreKit".
    ///
    /// A documented exception to "no `nonisolated(unsafe)`": this is
    /// write-once launch configuration read by synchronous logging calls
    /// (`AppLog.cache.error(...)` has to be callable from anywhere, so the value
    /// cannot sit behind an actor), and every alternative is a lock, a floor
    /// (`Mutex`, `Atomic`) or a breaking API. Set it before any task starts,
    /// exactly once; a later change is racy by definition.
    nonisolated(unsafe) public static var subsystem: String = Bundle.main.bundleIdentifier ?? "CoreKit"

    // MARK: - Provider

    /// The sink every `AppLog.<category>` call forwards to.
    ///
    /// Seeded from ``CoreKitPlatformDefaults/makeLogger(subsystem:)`` — the SAME
    /// per-target choice ``CoreKitPlatformAssembly`` registers, so an Apple
    /// consumer that never configures DI keeps writing to the unified log
    /// exactly as it did before this split (BR-L-05; measured — seeding with
    /// swift-log moved every such consumer's records to stdout). Replaced by the
    /// assembly with the resolved provider when a host configures DI. The seed is not a
    /// `try?` fallback that fabricates a verdict
    /// ([[a-try-with-a-literal-fallback-fabricates-a-verdict]]): it is a real,
    /// working logger, and it exists because `AppLog` is a deprecated *static*
    /// facade that predates the container and is called from places that have no
    /// resolver. Code that must fail loudly on a missing registration resolves
    /// `(any LoggingProviding).self` and gets `ContainerError.notRegistered`
    /// (BR-L-06).
    ///
    /// Same write-once rationale as ``subsystem``.
    nonisolated(unsafe) public static var provider: any LoggingProviding = CoreKitPlatformDefaults.makeLogger(
        subsystem: Bundle.main.bundleIdentifier ?? "CoreKit"
    )

    // MARK: - Categories

    /// General-purpose app logger
    nonisolated public static var app: CategoryLog { CategoryLog(.app) }

    /// Authentication and login flow
    nonisolated public static var auth: CategoryLog { CategoryLog(.auth) }

    /// Navigation and coordinator events
    nonisolated public static var navigation: CategoryLog { CategoryLog(.navigation) }

    /// Network requests and responses
    nonisolated public static var network: CategoryLog { CategoryLog(.network) }

    /// Tracking / analytics events
    nonisolated public static var tracking: CategoryLog { CategoryLog(.tracking) }

    /// Cache and persistence operations
    nonisolated public static var cache: CategoryLog { CategoryLog(.cache) }

    /// UI-related debug logs
    nonisolated public static var ui: CategoryLog { CategoryLog(.ui) }

    /// DI container operations
    nonisolated public static var di: CategoryLog { CategoryLog(.di) }

    /// Server-driven configuration and bootstrap
    nonisolated public static var config: CategoryLog { CategoryLog(.config) }

    /// Local notifications and reminders
    nonisolated public static var notification: CategoryLog { CategoryLog(.notification) }

    /// Timer engine (Pomodoro, focus sessions)
    nonisolated public static var timer: CategoryLog { CategoryLog(.timer) }

    /// StoreKit and in-app purchases
    nonisolated public static var storekit: CategoryLog { CategoryLog(.storekit) }

    /// Touch cursor overlay (QA mode)
    nonisolated public static var touchCursor: CategoryLog { CategoryLog(.touchCursor) }
}

// MARK: - CategoryLog

/// One ``LogCategory`` bound to ``AppLog/provider``.
///
/// It exists so `AppLog.cache.error("…")` keeps compiling: the method set is the
/// subset of `os.Logger`'s that the fleet's call sites actually use, and each
/// one forwards to the registered provider. `privacy` defaults to `.private`,
/// which is what a dynamic interpolation into `os.Logger` got before this
/// facade existed.
public struct CategoryLog: Sendable {
    public let category: LogCategory

    public init(_ category: LogCategory) {
        self.category = category
    }

    public func trace(_ message: String, privacy: LogPrivacy = .private) {
        AppLog.provider.log(.trace, category: category, message: message, privacy: privacy)
    }

    public func debug(_ message: String, privacy: LogPrivacy = .private) {
        AppLog.provider.log(.debug, category: category, message: message, privacy: privacy)
    }

    public func info(_ message: String, privacy: LogPrivacy = .private) {
        AppLog.provider.log(.info, category: category, message: message, privacy: privacy)
    }

    public func notice(_ message: String, privacy: LogPrivacy = .private) {
        AppLog.provider.log(.notice, category: category, message: message, privacy: privacy)
    }

    public func warning(_ message: String, privacy: LogPrivacy = .private) {
        AppLog.provider.log(.warning, category: category, message: message, privacy: privacy)
    }

    public func error(_ message: String, privacy: LogPrivacy = .private) {
        AppLog.provider.log(.error, category: category, message: message, privacy: privacy)
    }

    public func critical(_ message: String, privacy: LogPrivacy = .private) {
        AppLog.provider.log(.critical, category: category, message: message, privacy: privacy)
    }

    /// `os.Logger.fault` had no portable level — ``LogLevel/critical`` is the
    /// portable name for it and this keeps the old spelling compiling.
    public func fault(_ message: String, privacy: LogPrivacy = .private) {
        AppLog.provider.log(.critical, category: category, message: message, privacy: privacy)
    }
}

/// The type `AppLog`'s categories hand out.
///
/// Was `os.Logger` on Apple and `Logging.Logger` elsewhere — the split BR-L-07
/// bans. It is one type on every target now.
@available(*, deprecated, message: "Resolve `any LoggingProviding` instead; AppLog is a facade kept for one minor.")
public typealias AppLogger = CategoryLog

// MARK: - Address Utilities

/// Address debugging utilities
public struct DebugAddress: Sendable {
    public static func getObjAddress(_ ref: AnyObject) -> String {
        Unmanaged.passUnretained(ref).toOpaque().debugDescription
    }

    /// For usage on struct it should be: ```swift var struct = Struct(); Self.addressOf(&struct)```
    public static func getStrctAddress(_ ref: UnsafeRawPointer) -> String {
        Unmanaged<AnyObject>.fromOpaque(ref).toOpaque().debugDescription
    }

    public static func address(_ o: some AnyObject) -> String {
        let addr = unsafeBitCast(o, to: Int.self)
        return NSString(format: "%p", addr) as String
    }

    /// For usage on struct it should be: ```swift var struct = Struct(); Self.addressOf(&struct)```
    public static func addressOf(_ o: UnsafeRawPointer) -> String {
        let addr = Int(bitPattern: o)
        return String(format: "%p", addr)
    }
}
