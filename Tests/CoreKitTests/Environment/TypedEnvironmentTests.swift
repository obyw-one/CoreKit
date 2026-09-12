import CoreKit
import Foundation
import Testing

// MARK: - TypedEnvironmentTests

private enum SampleKey: String, EnvironmentKey {
    case host = "SAMPLE_HOST"
    case port = "SAMPLE_PORT"
    case live = "SAMPLE_LIVE"
}

private enum Suffix: String, EnvironmentKey {
    case host = "HOST"
}

@Suite("TypedEnvironment — the one typed reader of environment variables")
struct TypedEnvironmentTests {
    @Test("set values come back by key; unset and empty read as nil")
    func setUnsetEmpty() {
        let env = TypedEnvironment(["SAMPLE_HOST": "db.local", "SAMPLE_PORT": ""])
        #expect(env[SampleKey.host] == "db.local")
        #expect(env[SampleKey.port] == nil, "empty string folds to nil, like libpq")
        #expect(env[SampleKey.live] == nil)
        #expect(TypedEnvironment.empty[SampleKey.host] == nil)
    }

    @Test("prefixed lookup reads prefix + rawValue")
    func prefixedLookup() {
        let env = TypedEnvironment(["SHIKKI_DB_HOST": "10.0.0.2", "HOST": "wrong"])
        #expect(env[Suffix.host, prefix: "SHIKKI_DB_"] == "10.0.0.2")
        #expect(env[Suffix.host, prefix: "OTHER_"] == nil)
    }

    @Test("flag accepts the conventional truthy spellings only")
    func flags() {
        for raw in ["1", "true", "YES", "On"] {
            #expect(TypedEnvironment(["SAMPLE_LIVE": raw]).flag(SampleKey.live), "\(raw) should be truthy")
        }
        for raw in ["0", "false", "no", "", "maybe"] {
            #expect(!TypedEnvironment(["SAMPLE_LIVE": raw]).flag(SampleKey.live), "\(raw) should be falsy")
        }
        #expect(!TypedEnvironment.empty.flag(SampleKey.live))
    }

    @Test("presentKeys lists the declared keys that are set")
    func presentKeys() {
        let env = TypedEnvironment(["SAMPLE_HOST": "h", "SAMPLE_LIVE": "1", "UNRELATED": "x"])
        #expect(env.presentKeys(of: SampleKey.self) == [.host, .live])
    }

    @Test("current() snapshots the process environment through the same reader")
    func currentReadsProcess() {
        // PATH is set in every test process; the point is that the read goes
        // through the typed subscript, not that a specific value holds.
        enum PathKey: String, EnvironmentKey { case path = "PATH" }
        #expect(TypedEnvironment.current()[PathKey.path] != nil)
        #expect(!TypedEnvironment.current().isEmpty)
    }
}
