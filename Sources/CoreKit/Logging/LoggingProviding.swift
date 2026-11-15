//
//  LoggingProviding.swift
//  CoreKit
//
//  Spec c8fa126c, BR-L-02 / BR-L-07: logging is ONE protocol in the portable
//  target with ONE implementation per compilation target, never two code paths
//  through one call site. The choice is made by ``CoreKitPlatformAssembly`` and
//  nowhere else (BR-L-03); a caller resolves this protocol and never writes a
//  platform condition (BR-L-04).
//

import Foundation

/// A sink for log records.
///
/// Implementations are value types or otherwise thread-safe, because logging has
/// to be callable from any isolation context: `log` is synchronous and
/// `Sendable`-constrained on purpose. Making it `async` would mean a `Task` per
/// record at thousands of sites, and would reorder records relative to the work
/// they describe.
///
/// Resolve it, never name an implementation:
///
/// ```swift
/// let log = try resolve((any LoggingProviding).self)
/// log.error("Cache save failed: \(error)", category: .cache)
/// ```
///
/// A consumer that resolves this slot without registering
/// ``CoreKitPlatformAssembly`` gets `ContainerError.notRegistered` — a named
/// failure at the composition root, not a silent no-op (BR-L-06).
public protocol LoggingProviding: Sendable {
    /// Emit one record.
    /// - Parameters:
    ///   - level: Severity.
    ///   - category: Which subsystem category the record belongs to.
    ///   - message: The already-rendered message.
    ///   - privacy: Whether the message may be read outside this process.
    func log(_ level: LogLevel, category: LogCategory, message: String, privacy: LogPrivacy)
}

// MARK: - Convenience

public extension LoggingProviding {
    func trace(_ message: String, category: LogCategory = .app, privacy: LogPrivacy = .private) {
        log(.trace, category: category, message: message, privacy: privacy)
    }

    func debug(_ message: String, category: LogCategory = .app, privacy: LogPrivacy = .private) {
        log(.debug, category: category, message: message, privacy: privacy)
    }

    func info(_ message: String, category: LogCategory = .app, privacy: LogPrivacy = .private) {
        log(.info, category: category, message: message, privacy: privacy)
    }

    func notice(_ message: String, category: LogCategory = .app, privacy: LogPrivacy = .private) {
        log(.notice, category: category, message: message, privacy: privacy)
    }

    func warning(_ message: String, category: LogCategory = .app, privacy: LogPrivacy = .private) {
        log(.warning, category: category, message: message, privacy: privacy)
    }

    func error(_ message: String, category: LogCategory = .app, privacy: LogPrivacy = .private) {
        log(.error, category: category, message: message, privacy: privacy)
    }

    func critical(_ message: String, category: LogCategory = .app, privacy: LogPrivacy = .private) {
        log(.critical, category: category, message: message, privacy: privacy)
    }
}
