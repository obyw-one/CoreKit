import CoreKit
import Foundation
import Testing

// MARK: - Fixtures

private enum SampleKey: String, EnvKeyProviding {
    case brokerHost = "SAMPLE_BROKER_HOST"
    case verbose = "SAMPLE_VERBOSE"
    case token = "SAMPLE_TOKEN"
    case port = "SAMPLE_PORT"

    var defaultValue: String? {
        switch self {
        case .verbose: "false"
        case .brokerHost, .token, .port: nil
        }
    }
}

/// Declares no default anywhere: the protocol's own default must apply.
private enum BareKey: String, EnvKeyProviding {
    case one = "BARE_ONE"
}

// MARK: - EnvKeyProvidingTests

@Suite("EnvKeyProviding — the typed env vocabulary, graduated to CoreKit (BR-RP-12)")
struct EnvKeyProvidingTests {

    @Test("a conformer is an EnvironmentKey: TypedEnvironment reads it, and the audit lists it")
    func isAnEnvironmentKey() {
        let env = TypedEnvironment(["SAMPLE_BROKER_HOST": "broker.local", "UNRELATED": "x"])
        #expect(env[SampleKey.brokerHost] == "broker.local")
        #expect(env.presentKeys(of: SampleKey.self) == [.brokerHost])
        #expect(SampleKey.allCases.count == 4)
    }

    @Test("a key that declares no default has none")
    func protocolDefaultIsNil() {
        #expect(BareKey.one.defaultValue == nil)
        #expect(SampleKey.brokerHost.defaultValue == nil)
    }

    @Test("resolve: the variable wins, then the key's default, then nil")
    func resolveOrder() {
        #expect(TypedEnvironment(["SAMPLE_VERBOSE": "true"]).resolve(SampleKey.verbose) == "true")
        #expect(TypedEnvironment.empty.resolve(SampleKey.verbose) == "false")
        #expect(TypedEnvironment.empty.resolve(SampleKey.brokerHost) == nil)
    }

    @Test("resolve: an empty variable counts as unset, so the default applies")
    func resolveEmptyFallsToDefault() {
        #expect(TypedEnvironment(["SAMPLE_VERBOSE": ""]).resolve(SampleKey.verbose) == "false")
    }

    @Test("require: returns the value, and stops on a missing or empty one — no fallback")
    func requireStopsOnMissing() throws {
        #expect(try TypedEnvironment(["SAMPLE_BROKER_HOST": "broker.local"]).require(SampleKey.brokerHost) == "broker.local")
        #expect(throws: EnvKeyError.missing(name: "SAMPLE_BROKER_HOST")) { try TypedEnvironment.empty.require(SampleKey.brokerHost) }
        #expect(throws: EnvKeyError.missing(name: "SAMPLE_BROKER_HOST")) {
            try TypedEnvironment(["SAMPLE_BROKER_HOST": ""]).require(SampleKey.brokerHost)
        }
    }

    @Test("require never consults a key's default: a required key cannot be quietly satisfied by one")
    func requireIgnoresDefault() {
        #expect(throws: EnvKeyError.missing(name: "SAMPLE_VERBOSE")) { try TypedEnvironment.empty.require(SampleKey.verbose) }
    }

    @Test("require as: parses the value, and a malformed one names the type but not the value")
    func requireParses() throws {
        #expect(try TypedEnvironment(["SAMPLE_PORT": "4222"]).require(SampleKey.port, as: Int.self) == 4222)
        #expect(try TypedEnvironment(["SAMPLE_VERBOSE": "true"]).require(SampleKey.verbose, as: Bool.self))
        let secret = "s3cr3t-not-a-number"
        let env = TypedEnvironment(["SAMPLE_PORT": secret])
        let error = #expect(throws: EnvKeyError.self) { try env.require(SampleKey.port, as: Int.self) }
        #expect(error == .malformed(name: "SAMPLE_PORT", expected: "Int"))
        let message = String(describing: error)
        #expect(!message.contains(secret), "an error must not echo a value that may be a token")
    }

    @Test("a missing-key error names the variable")
    func errorDescriptions() {
        #expect(EnvKeyError.missing(name: "X").description.contains("X"))
        #expect(EnvKeyError.malformed(name: "X", expected: "Int").errorDescription?.contains("Int") == true)
    }

    @Test("layered: this snapshot wins, the base fills the gaps")
    func layeredPrecedence() {
        let settings = TypedEnvironment(["SAMPLE_BROKER_HOST": "from-settings", "SAMPLE_PORT": "1111"])
        let process = TypedEnvironment(["SAMPLE_BROKER_HOST": "from-process", "SAMPLE_TOKEN": "t"])
        let merged = process.layered(over: settings)
        #expect(merged[SampleKey.brokerHost] == "from-process")
        #expect(merged[SampleKey.port] == "1111")
        #expect(merged[SampleKey.token] == "t")
    }

    @Test("layered: an empty variable does not shadow a configured setting")
    func layeredEmptyDoesNotShadow() {
        let settings = TypedEnvironment(["SAMPLE_BROKER_HOST": "from-settings"])
        let process = TypedEnvironment(["SAMPLE_BROKER_HOST": ""])
        #expect(process.layered(over: settings)[SampleKey.brokerHost] == "from-settings")
    }

    @Test("EnvValue: one truthy set, trimmed and case-insensitive")
    func envValueTruthy() {
        for raw in ["1", "true", "YES", " On ", "TRUE"] { #expect(EnvValue.isTruthy(raw), "\(raw)") }
        for raw in ["0", "false", "", "  ", "maybe"] { #expect(!EnvValue.isTruthy(raw), "\(raw)") }
        #expect(!EnvValue.isTruthy(nil))
        #expect(EnvValue.truthyTokens == ["1", "true", "yes", "on"])
    }

    @Test("EnvValue.normalized trims and folds blank to nil")
    func envValueNormalized() {
        #expect(EnvValue.normalized("  v \n") == "v")
        #expect(EnvValue.normalized("   ") == nil)
        #expect(EnvValue.normalized(nil) == nil)
    }

    @Test("TypedEnvironment.flag agrees with EnvValue on every token")
    func flagAndEnvValueAgree() {
        for raw in ["1", "true", "yes", "on", "0", "false", "no", "off", "maybe"] {
            let env = TypedEnvironment(["SAMPLE_VERBOSE": raw])
            #expect(env.flag(SampleKey.verbose) == EnvValue.truthyTokens.contains(raw.lowercased()), "\(raw)")
        }
    }
}
