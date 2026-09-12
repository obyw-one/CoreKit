//
//  DateFormatter+Extensions.swift
//  CoreKit
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 04/04/2024.
//

import Foundation

// MARK: - Shared Date Formatters (DRY — single source of truth)

public extension DateFormatter {
    /// PocketBase UTC ISO 8601 with fractional seconds and space separator.
    /// Example: `2024-04-04 13:47:54.692Z`
    static var pocketbase: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(abbreviation: "UTC")
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withSpaceBetweenDateAndTime]
        return f
    }

    /// Short display: `2026-03-26 14:30` — local timezone.
    /// Use for: CLI output, status, schedule list, dashboard, logs.
    static var shortDisplay: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        return f
    }

    /// Compact display: `Mar 26 14:30` — local timezone.
    /// Use for: tmux status bar, mini mode, tight spaces.
    static var compactDisplay: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "MMM dd HH:mm"
        f.timeZone = .current
        return f
    }

    /// Time only: `14:30:05` — local timezone.
    /// Use for: event log, real-time feeds.
    static var timeOnly: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        return f
    }

    /// Date only: `2026-03-26` — local timezone.
    /// Use for: file names, report headers, daily grouping.
    static var dateOnly: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }
}

// MARK: - Shared ISO8601 Formatters

public extension ISO8601DateFormatter {
    /// Standard ISO 8601 for API communication and DB storage.
    /// Example: `2026-03-26T14:30:05Z`
    static var standard: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    /// ISO 8601 with fractional seconds for high-precision timestamps.
    /// Example: `2026-03-26T14:30:05.123Z`
    static var precise: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}

// MARK: - Date Convenience

public extension Date {
    /// Format with the shared short display formatter.
    var shortDisplay: String {
        DateFormatter.shortDisplay.string(from: self)
    }

    /// Format with the shared compact display formatter.
    var compactDisplay: String {
        DateFormatter.compactDisplay.string(from: self)
    }

    /// Format as time only.
    var timeOnly: String {
        DateFormatter.timeOnly.string(from: self)
    }

    /// Format as date only.
    var dateOnly: String {
        DateFormatter.dateOnly.string(from: self)
    }

    /// Format as standard ISO 8601.
    var iso8601: String {
        ISO8601DateFormatter.standard.string(from: self)
    }

    /// Format as precise ISO 8601 (with fractional seconds).
    var iso8601Precise: String {
        ISO8601DateFormatter.precise.string(from: self)
    }

    /// Human-readable relative time: "2h ago", "3d ago", "just now".
    var relativeDisplay: String {
        let interval = Date().timeIntervalSince(self)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 604_800 { return "\(Int(interval / 86400))d ago" }
        return self.shortDisplay
    }
}

// MARK: - JSONDecoder PocketBase Strategy

public extension JSONDecoder {
    /// Returns a `@Sendable` closure that decodes PocketBase-formatted date strings.
    /// The returned closure captures no mutable state and is safe to hand to
    /// `JSONDecoder.DateDecodingStrategy.custom(_:)` under Swift 6 strict concurrency.
    func pocketbaseDateDecodingStrategy() -> @Sendable (_ decoder: any Decoder) throws -> Date {
        pocketbaseDateDecoder
    }
}

/// Top-level `@Sendable` PocketBase date decoder. Lives at file scope so it never
/// captures non-Sendable context when referenced from `.custom(...)` strategies.
@Sendable
public func pocketbaseDateDecoder(_ decoder: any Decoder) throws -> Date {
    let container = try decoder.singleValueContainer()
    let dateString = try container.decode(String.self)

    if let date = DateFormatter.pocketbase.date(from: dateString) {
        return date
    } else {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date string \(dateString)")
    }
}
