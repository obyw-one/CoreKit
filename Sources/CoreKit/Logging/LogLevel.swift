//
//  LogLevel.swift
//  CoreKit
//
//  Spec c8fa126c, BR-L-02: a capability's value types are declared once, in the
//  portable target, and depend on Foundation only. This enum is the severity
//  vocabulary both ``OSLogLogger`` and ``SwiftLogLogger`` map onto, so a call
//  site names a level and never a platform's own level type.
//

import Foundation

/// Severity of a log record, ordered least to most severe.
///
/// The seven cases are the intersection that both backends can express without
/// inventing one: `os.Logger` has `trace/debug/info/notice/warning/error/critical`
/// as methods (`trace` aliases `debug`), and swift-log's `Logger.Level` has the
/// same seven plus `fault`. `fault` is deliberately absent — it exists only on
/// Apple, and a level one backend cannot express is not a portable level.
public enum LogLevel: String, Sendable, CaseIterable, Codable, Comparable, CustomStringConvertible {
    case trace
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    /// Monotonic rank, least severe first. Used for ordering and for filtering.
    public var severity: Int {
        switch self {
        case .trace: return 0
        case .debug: return 1
        case .info: return 2
        case .notice: return 3
        case .warning: return 4
        case .error: return 5
        case .critical: return 6
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.severity < rhs.severity
    }

    public var description: String { rawValue }
}
