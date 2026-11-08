import CoreKit
import CoreKitTestSupport
import Foundation
import Testing

// MARK: - AppConfigTests

@Suite("AppConfig — the server-driven facts, one wire shape for every backing (BR-RP-13)")
struct AppConfigTests {

    private func decode(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }

    /// The PocketBase record, a raw wire fixture loaded by URL.
    private func record() throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: FixtureFile.data("app-config-record.json"))
    }

    private func keys(of data: Data) throws -> Set<String> {
        guard case .object(let object) = JSONValue(untyped: try JSONSerialization.jsonObject(with: data)) else { return [] }
        return Set(object.keys)
    }

    @Test("it decodes the snake_case record PocketBase serves, ignoring the system fields around it")
    func decodesRecord() throws {
        let config = try record()
        #expect(config.id == "rec123")
        #expect(config.appId == "demo")
        #expect(config.minVersion == "1.2.0")
        #expect(config.latestVersion == "1.4.1")
        #expect(!config.killSwitch)
        #expect(config.maintenanceMode)
        #expect(config.maintenanceMessage == "Back soon")
        #expect(config.featureFlags.values == ["feature_x": .bool(true), "max_items": .int(5)])
        #expect(config.configData == ["tagline": "hello"])
    }

    @Test("encode half: the model writes exactly the wire keys the record carries — a renamed coding key fails here")
    func encodePinsTheWireKeys() throws {
        let encoded = try JSONEncoder().encode(try record())
        let fixtureKeys = try keys(of: FixtureFile.data("app-config-record.json"))
        // The PocketBase system fields and `env` are the server's, not the model's.
        let notInTheModel: Set<String> = ["collectionId", "collectionName", "created", "env"]
        #expect(try keys(of: encoded) == fixtureKeys.subtracting(notInTheModel))
        #expect(try JSONDecoder().decode(AppConfig.self, from: encoded) == record())
    }

    @Test("optional fields may be absent")
    func optionalFields() throws {
        let config = try decode("""
        {"id":"r","app_id":"demo","min_version":"1.0.0","latest_version":"1.0.0","kill_switch":false,
         "maintenance_mode":false,"feature_flags":{}}
        """)
        #expect(config.maintenanceMessage == nil)
        #expect(config.configData == nil)
        #expect(config.featureFlags.values.isEmpty)
    }

    @Test("a record missing a required field is rejected, not defaulted")
    func missingRequiredField() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"id":"r","app_id":"demo","min_version":"1.0.0"}"#)
        }
    }

    @Test("it round-trips through its own encoding")
    func roundTrip() throws {
        let original = try record()
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(AppConfig.self, from: data) == original)
    }

    @Test("the kill switch outranks maintenance; neither means not blocked")
    func blockPrecedence() throws {
        let base = try record()
        #expect(base.block == .maintenance(message: "Back soon"))
        let killed = AppConfig(
            id: base.id, appId: base.appId, minVersion: base.minVersion, latestVersion: base.latestVersion,
            killSwitch: true, maintenanceMode: true, maintenanceMessage: nil, featureFlags: base.featureFlags, configData: nil)
        #expect(killed.block == .killSwitch(message: nil))
        #expect(killed.block?.message == nil)
        let open = AppConfig(
            id: "r", appId: "demo", minVersion: "1", latestVersion: "1", killSwitch: false, maintenanceMode: false,
            maintenanceMessage: "ignored", featureFlags: RemoteFeatureFlags(), configData: nil)
        #expect(open.block == nil)
    }

    @Test("the version floor and the latest version compare numerically")
    func versions() throws {
        let config = try record()
        #expect(config.requiresUpdate(installedVersion: "1.1.9"))
        #expect(!config.requiresUpdate(installedVersion: "1.2.0"))
        #expect(!config.requiresUpdate(installedVersion: "1.10.0"), "1.10 is newer than 1.2, not older")
        #expect(config.hasNewerVersion(installedVersion: "1.4.0"))
        #expect(!config.hasNewerVersion(installedVersion: "1.4.1"))
    }

    @Test("the storage key names the app and the environment")
    func storageKey() {
        #expect(AppConfigQuery(appId: "demo", environment: "prod").storageKey == "demo-prod")
        #expect(AppConfigQuery(appId: "demo", environment: "prod") != AppConfigQuery(appId: "demo", environment: "preprod"))
    }
}
