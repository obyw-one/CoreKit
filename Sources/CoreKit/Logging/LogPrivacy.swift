//
//  LogPrivacy.swift
//  CoreKit
//
//  Spec c8fa126c, BR-L-05: no behaviour change at a call site that was already
//  portable. `os.Logger` redacts a dynamically interpolated string by default,
//  so the facade's default here is `.private` — anything else would quietly turn
//  every existing `AppLog.cache.error("… \(error)")` into a public record.
//

import Foundation

/// Whether a log record's message may be read outside the emitting process.
///
/// Apple's unified logging redacts dynamic (non-numeric) interpolation unless the
/// call site marks it `public`; swift-log has no such notion, so
/// ``SwiftLogLogger`` implements the same rule by hand. Declaring privacy in the
/// portable protocol is what makes the two backends behave the same way rather
/// than merely compile the same way.
public enum LogPrivacy: String, Sendable, CaseIterable, Codable {
    /// Redacted when the log is read from another process. The default.
    case `private`
    /// Readable by anything that can read the log.
    case `public`
}
