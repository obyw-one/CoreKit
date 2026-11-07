//
//  AppConfig.swift
//  CoreKit
//
//  Promoted from WabiSabi's `AppConfig` (spec d3f8a1b2, BR-RP-13): the facts
//  only the SERVER knows, in a shape every configuration backing — PocketBase,
//  a SQL row, a cached file — decodes identically.
//

import Foundation

// MARK: - AppConfigQuery

/// Which app's configuration is being asked for: the app's slug and the name
/// of the environment it runs against. Both are the host's values, injected —
/// CoreKit knows no app and no environment.
public struct AppConfigQuery: Sendable, Hashable, Codable {
    public let appId: String
    public let environment: String

    public init(appId: String, environment: String) {
        self.appId = appId
        self.environment = environment
    }

    /// The key a repository stores this app's configuration under.
    public var storageKey: String { "\(appId)-\(environment)" }
}

// MARK: - AppBlock

/// Why the app must not run, as the server set it. The message is the
/// server's own words (nil when it gave none): CoreKit supplies no copy of
/// its own, so the host localises or words the default.
public enum AppBlock: Sendable, Equatable {
    case killSwitch(message: String?)
    case maintenance(message: String?)

    public var message: String? {
        switch self {
        case .killSwitch(let message), .maintenance(let message): message
        }
    }
}

// MARK: - AppConfig

/// Server-driven app configuration: the kill switch, maintenance mode, the
/// version floor, remote feature-flag overrides and free-form data.
///
/// What the build knows — its environment, its hosts, its analytics id — is
/// NOT here; the typed environment owns those. There is no built-in instance:
/// when the server has not answered and the cache is empty, the service's
/// `currentConfig` is `nil` and the app runs on its local defaults. A
/// configuration is never invented.
///
/// The wire shape is the snake_case record PocketBase serves, and the same
/// record a SQL row or a cached file holds, so one `Codable` decodes them all.
public struct AppConfig: Sendable, Equatable, Codable {
    public let id: String
    public let appId: String
    public let minVersion: String
    public let latestVersion: String
    public let killSwitch: Bool
    public let maintenanceMode: Bool
    public let maintenanceMessage: String?
    public let featureFlags: RemoteFeatureFlags
    public let configData: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case id
        case appId = "app_id"
        case minVersion = "min_version"
        case latestVersion = "latest_version"
        case killSwitch = "kill_switch"
        case maintenanceMode = "maintenance_mode"
        case maintenanceMessage = "maintenance_message"
        case featureFlags = "feature_flags"
        case configData = "config_data"
    }

    public init(
        id: String,
        appId: String,
        minVersion: String,
        latestVersion: String,
        killSwitch: Bool,
        maintenanceMode: Bool,
        maintenanceMessage: String?,
        featureFlags: RemoteFeatureFlags,
        configData: [String: String]?
    ) {
        self.id = id
        self.appId = appId
        self.minVersion = minVersion
        self.latestVersion = latestVersion
        self.killSwitch = killSwitch
        self.maintenanceMode = maintenanceMode
        self.maintenanceMessage = maintenanceMessage
        self.featureFlags = featureFlags
        self.configData = configData
    }

    /// The reason the app is blocked, if it is. The kill switch outranks maintenance.
    public var block: AppBlock? {
        if killSwitch { return .killSwitch(message: maintenanceMessage) }
        if maintenanceMode { return .maintenance(message: maintenanceMessage) }
        return nil
    }

    /// `true` when `installedVersion` is older than the version floor the
    /// server set: the app must update before it may run.
    public func requiresUpdate(installedVersion: String) -> Bool {
        VersionComparator.compare(installedVersion, minVersion) == .orderedAscending
    }

    /// `true` when a newer version than `installedVersion` is available.
    public func hasNewerVersion(installedVersion: String) -> Bool {
        VersionComparator.compare(installedVersion, latestVersion) == .orderedAscending
    }
}
