import CoreKit
import Foundation

// MARK: - ConfigEndpointHarness

/// A configuration source wired for the suite: the endpoint, the query it was
/// seeded for, the configuration it was seeded with, and a query nothing was
/// seeded for.
public struct ConfigEndpointHarness: Sendable {
    public let label: String
    public let endpoint: any ConfigEndpoint
    public let query: AppConfigQuery
    public let expected: AppConfig
    public let unknownQuery: AppConfigQuery

    public init(
        label: String, endpoint: any ConfigEndpoint, query: AppConfigQuery, expected: AppConfig, unknownQuery: AppConfigQuery
    ) {
        self.label = label
        self.endpoint = endpoint
        self.query = query
        self.expected = expected
        self.unknownQuery = unknownQuery
    }
}

// MARK: - ConfigEndpointConformance

/// What a ``ConfigEndpoint`` must do, whatever it reads from (BR-RP-13, W5):
/// the same ``AppConfig`` comes out of every backing, so swapping the backing
/// changes no consumer. NetKit's PocketBase endpoint and BackendKit's SQL one run
/// this suite from their own test targets, seeding ``sampleConfig(for:)`` into
/// their store.
public enum ConfigEndpointConformance {

    public enum Check: String, CaseIterable, Sendable, CustomStringConvertible {
        case returnsTheSeededConfig
        case preservesFlagsAndData
        case reportsAnUnknownAppAsNotFound
        case answersRepeatedly

        public var description: String { rawValue }
    }

    /// A fully populated configuration for `query`: every field set, flags of
    /// every scalar kind, free-form data and a maintenance message.
    public static func sampleConfig(for query: AppConfigQuery) -> AppConfig {
        AppConfig(
            id: "record-\(query.appId)-\(query.environment)",
            appId: query.appId,
            minVersion: "1.2.0",
            latestVersion: "1.4.1",
            killSwitch: false,
            maintenanceMode: true,
            maintenanceMessage: "Back shortly — é",
            featureFlags: RemoteFeatureFlags([
                "feature_x": .bool(true), "max_items": .int(25), "ratio": .double(0.5), "theme": .string("dark"),
            ]),
            configData: ["support_contact": "help@example.test", "tagline": "café"])
    }

    public static func run(_ check: Check, on harness: ConfigEndpointHarness) async -> [String] {
        let prefix = "\(harness.label) / \(check.rawValue)"
        do {
            switch check {
            case .returnsTheSeededConfig:
                let config = try await harness.endpoint.fetchConfig(harness.query)
                return config == harness.expected ? [] : ["\(prefix): returned \(config), expected \(harness.expected)"]

            case .preservesFlagsAndData:
                let config = try await harness.endpoint.fetchConfig(harness.query)
                var violations: [String] = []
                if config.featureFlags != harness.expected.featureFlags {
                    violations.append("\(prefix): feature flags changed: \(config.featureFlags.values)")
                }
                if config.configData != harness.expected.configData {
                    violations.append("\(prefix): config data changed: \(String(describing: config.configData))")
                }
                if config.maintenanceMessage != harness.expected.maintenanceMessage {
                    violations.append("\(prefix): the maintenance message changed")
                }
                return violations

            case .reportsAnUnknownAppAsNotFound:
                do {
                    let config = try await harness.endpoint.fetchConfig(harness.unknownQuery)
                    return ["\(prefix): answered \(config) for an app nothing was seeded for"]
                } catch let error as ConfigEndpointError {
                    return error == .notFound(harness.unknownQuery) ? [] : ["\(prefix): threw \(error)"]
                } catch {
                    return ["\(prefix): threw \(error) instead of ConfigEndpointError.notFound"]
                }

            case .answersRepeatedly:
                let first = try await harness.endpoint.fetchConfig(harness.query)
                let second = try await harness.endpoint.fetchConfig(harness.query)
                return first == second ? [] : ["\(prefix): two fetches disagreed"]
            }
        } catch {
            return ["\(prefix): threw unexpectedly: \(error)"]
        }
    }

    public static func runAll(on harness: ConfigEndpointHarness) async -> [String] {
        var all: [String] = []
        for check in Check.allCases { all += await run(check, on: harness) }
        return all
    }
}
