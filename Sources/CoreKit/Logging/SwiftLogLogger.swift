//
//  SwiftLogLogger.swift
//  CoreKit
//
//  Spec c8fa126c, BR-L-09: the portable product's dependencies are Foundation +
//  swift-crypto + swift-log. swift-log is pure Swift and builds on every target
//  the fleet ships, so this implementation is declared UNCONDITIONALLY in the
//  portable target — no `#if` (BR-L-04). It is the registered logger off Apple,
//  and it stays available on Apple so a host that wants one log pipeline across
//  macOS and Linux can register it there too.
//

import Foundation
import Logging

/// ``LoggingProviding`` over swift-log.
///
/// One `Logging.Logger` per ``LogCategory``, built once at init: a swift-log
/// `Logger` is a struct over a shared handler, so 13 of them cost 13 labels and
/// no handlers. The label is `"<subsystem>.<category>"`, which is the shape
/// `os.Logger(subsystem:category:)` prints, so a line read off a Linux daemon
/// and a line read off Console name the same thing.
///
/// `privacy` is honoured by hand, and the mapping is the part worth reading.
/// `os_log` redacts a `.private` value *when the log is read from another
/// process*; a locally run process sees its own private data (which is why
/// Xcode's console shows it). swift-log writes to this process's own stream, so
/// the faithful analogue of "the emitting process reads its own log" is: emit it.
/// Redacting by default would silently delete every Linux diagnostic CoreKit
/// emits today, which is a behaviour change at a call site (BR-L-05) in the
/// opposite direction. A host that ships its log stream off-box sets
/// ``redactsPrivateValues`` and gets `<private>` instead.
public struct SwiftLogLogger: LoggingProviding {
    private let loggers: [LogCategory: Logging.Logger]

    /// When true, a `.private` message is emitted as `<private>` and its text is
    /// dropped. Default false: see the type's note on the `os_log` mapping.
    public let redactsPrivateValues: Bool

    /// - Parameters:
    ///   - subsystem: The label prefix, e.g. a bundle identifier.
    ///   - minimumLevel: Records below this level are dropped by swift-log itself.
    ///   - redactsPrivateValues: Set it when this process's log stream leaves the box.
    public init(subsystem: String, minimumLevel: LogLevel = .debug, redactsPrivateValues: Bool = false) {
        self.redactsPrivateValues = redactsPrivateValues
        var built: [LogCategory: Logging.Logger] = [:]
        built.reserveCapacity(LogCategory.allCases.count)
        for category in LogCategory.allCases {
            var logger = Logging.Logger(label: "\(subsystem).\(category.rawValue)")
            logger[metadataKey: "category"] = "\(category.rawValue)"
            logger.logLevel = Self.swiftLogLevel(for: minimumLevel)
            built[category] = logger
        }
        loggers = built
    }

    public func log(_ level: LogLevel, category: LogCategory, message: String, privacy: LogPrivacy) {
        // A category is always present: `loggers` is built from
        // `LogCategory.allCases`, so this is total by construction. If a case is
        // ever added without rebuilding the table the record must still be
        // emitted rather than dropped, so the fallback builds one on the spot
        // instead of returning — a dropped log is the failure this guards.
        let logger = loggers[category] ?? Logging.Logger(label: category.rawValue)
        let rendered = (redactsPrivateValues && privacy == .private) ? "<private>" : message
        logger.log(level: Self.swiftLogLevel(for: level), "\(rendered)")
    }

    private static func swiftLogLevel(for level: LogLevel) -> Logging.Logger.Level {
        switch level {
        case .trace: return .trace
        case .debug: return .debug
        case .info: return .info
        case .notice: return .notice
        case .warning: return .warning
        case .error: return .error
        case .critical: return .critical
        }
    }
}
