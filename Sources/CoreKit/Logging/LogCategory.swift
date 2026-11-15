//
//  LogCategory.swift
//  CoreKit
//
//  Spec c8fa126c, BR-L-07: `AppLog`'s 13 categories become one typed
//  `CaseIterable` enum rather than 13 static accessors
//  ([[a-family-of-owned-files-is-one-typed-caseiterable-enum]]). The raw value
//  is the `os.Logger` category string, byte for byte, so Console and
//  `log stream --predicate 'category == "cache"'` keep working unchanged.
//

import Foundation

/// The subsystem's log categories.
///
/// One case per category `AppLog` exposed before the capability split, with the
/// same string, so an existing Console filter or `log` predicate is unaffected.
public enum LogCategory: String, Sendable, CaseIterable, Codable, CustomStringConvertible {
    /// General-purpose app logger.
    case app
    /// Authentication and login flow.
    case auth
    /// Navigation and coordinator events.
    case navigation
    /// Network requests and responses.
    case network
    /// Tracking / analytics events.
    case tracking
    /// Cache and persistence operations.
    case cache
    /// UI-related debug logs.
    case ui
    /// DI container operations.
    case di
    /// Server-driven configuration and bootstrap.
    case config
    /// Local notifications and reminders.
    case notification
    /// Timer engine (Pomodoro, focus sessions).
    case timer
    /// StoreKit and in-app purchases.
    case storekit
    /// Touch cursor overlay (QA mode).
    case touchCursor = "touch-cursor"

    public var description: String { rawValue }
}
