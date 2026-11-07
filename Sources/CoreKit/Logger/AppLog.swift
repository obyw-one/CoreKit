//
//  AppLog.swift
//  CoreKit
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 02/04/2024.
//

import Foundation
#if canImport(os)
import os

/// The logger type `AppLog` hands out: `os.Logger` on Apple platforms.
public typealias AppLogger = os.Logger
#else
import Logging

/// The logger type `AppLog` hands out: swift-log `Logger` where `os` is absent (Linux, Windows).
public typealias AppLogger = Logging.Logger
#endif

// MARK: - OSLog-based Logger

/// App-wide logger namespace — named `AppLog` to avoid conflict with `os.Logger`
/// which is exported as `Logger` by `import os`. On platforms without `os` (Linux) the
/// same API is backed by swift-log.
///
/// Usage: `AppLog.app.debug("message")`, `AppLog.cache.error("...")`, etc.
///
/// **Setup:** Each app must set the subsystem at launch:
/// ```swift
/// AppLog.subsystem = "com.example.MyApp"
/// ```
public enum AppLog: Sendable {
    // MARK: - Configurable Subsystem

    /// The subsystem identifier used by all loggers.
    /// Must be set by the host app at launch (e.g., in `App.init()`).
    /// Defaults to the main bundle identifier if available, otherwise "CoreKit".
    nonisolated(unsafe) public static var subsystem: String = Bundle.main.bundleIdentifier ?? "CoreKit"

    // MARK: - Factory

    nonisolated private static func makeLogger(category: String) -> AppLogger {
        #if canImport(os)
        os.Logger(subsystem: subsystem, category: category)
        #else
        var logger = Logging.Logger(label: "\(subsystem).\(category)")
        logger[metadataKey: "category"] = "\(category)"
        return logger
        #endif
    }

    // MARK: - Categories

    /// General-purpose app logger
    nonisolated public static var app: AppLogger {
        makeLogger(category: "app")
    }

    /// Authentication and login flow
    nonisolated public static var auth: AppLogger {
        makeLogger(category: "auth")
    }

    /// Navigation and coordinator events
    nonisolated public static var navigation: AppLogger {
        makeLogger(category: "navigation")
    }

    /// Network requests and responses
    nonisolated public static var network: AppLogger {
        makeLogger(category: "network")
    }

    /// Tracking / analytics events
    nonisolated public static var tracking: AppLogger {
        makeLogger(category: "tracking")
    }

    /// Cache and persistence operations
    nonisolated public static var cache: AppLogger {
        makeLogger(category: "cache")
    }

    /// UI-related debug logs
    nonisolated public static var ui: AppLogger {
        makeLogger(category: "ui")
    }

    /// DI container operations
    nonisolated public static var di: AppLogger {
        makeLogger(category: "di")
    }

    /// Server-driven configuration and bootstrap
    nonisolated public static var config: AppLogger {
        makeLogger(category: "config")
    }

    /// Local notifications and reminders
    nonisolated public static var notification: AppLogger {
        makeLogger(category: "notification")
    }

    /// Timer engine (Pomodoro, focus sessions)
    nonisolated public static var timer: AppLogger {
        makeLogger(category: "timer")
    }

    /// StoreKit and in-app purchases
    nonisolated public static var storekit: AppLogger {
        makeLogger(category: "storekit")
    }

    /// Touch cursor overlay (QA mode)
    nonisolated public static var touchCursor: AppLogger {
        makeLogger(category: "touch-cursor")
    }
}

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
