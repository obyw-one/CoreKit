//
//  OSLogLogger.swift
//  CoreKit
//
//  Spec c8fa126c, BR-L-03: `Sources/CoreKit/Platform/` is the ONE subtree in the
//  portable target where a platform condition may appear — it is the DI
//  assembly and the implementations it chooses between, and the BR-L-04 ratchet
//  excludes it BY PATH, never by filename
//  ([[a-ratchet-scopes-a-folder-subtree-never-a-filename-list]]).
//
//  Everything above this directory — the protocol, the levels, the categories,
//  every call site — is unconditional.
//

import Foundation

#if canImport(os)
    import os

    /// ``LoggingProviding`` over Apple's unified logging.
    ///
    /// One `os.Logger` per ``LogCategory``, built at init with
    /// `os.Logger(subsystem:category:)` and the category's raw value, so the
    /// subsystem/category pair is byte-for-byte what `AppLog` produced before the
    /// capability split: an existing Console filter or
    /// `log stream --predicate 'category == "cache"'` is unaffected (BR-L-05).
    ///
    /// Privacy is explicit at the `os_log` call rather than inherited from
    /// interpolation defaults, because the message arrives here already rendered
    /// to a `String` and a rendered string has no interpolation left to classify.
    /// ``LogPrivacy/private`` is the facade's default, which is what a dynamic
    /// interpolation got before.
    public struct OSLogLogger: LoggingProviding {
        private let loggers: [LogCategory: os.Logger]

        /// - Parameter subsystem: The `os_log` subsystem, e.g. a bundle identifier.
        public init(subsystem: String) {
            var built: [LogCategory: os.Logger] = [:]
            built.reserveCapacity(LogCategory.allCases.count)
            for category in LogCategory.allCases {
                built[category] = os.Logger(subsystem: subsystem, category: category.rawValue)
            }
            loggers = built
        }

        public func log(_ level: LogLevel, category: LogCategory, message: String, privacy: LogPrivacy) {
            // Total by construction: `loggers` is built from `allCases`. The
            // fallback builds one rather than returning, because a dropped log
            // is the failure this guards against.
            let logger = loggers[category] ?? os.Logger(subsystem: "CoreKit", category: category.rawValue)
            switch privacy {
            case .private:
                logger.log(level: Self.osLogType(for: level), "\(message, privacy: .private)")
            case .public:
                logger.log(level: Self.osLogType(for: level), "\(message, privacy: .public)")
            }
        }

        private static func osLogType(for level: LogLevel) -> OSLogType {
            switch level {
            // `os` has no distinct trace; `AppLog`'s callers used `.debug` for it
            // and `os.Logger.trace` is itself documented as an alias of debug.
            case .trace, .debug: return .debug
            case .info: return .info
            case .notice: return .default
            // Apple's own mapping, not a collapse of ours: `Logger.warning` and
            // `Logger.error` both emit `OSLogType.error`, and `Logger.critical`
            // emits `.fault`. The two levels stay distinct in the portable
            // vocabulary and in swift-log; `os` is the backend that merges them.
            case .warning, .error: return .error
            case .critical: return .fault
            }
        }
    }
#endif
