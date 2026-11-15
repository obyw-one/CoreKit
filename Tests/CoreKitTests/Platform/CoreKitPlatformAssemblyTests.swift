import Foundation
import Testing
@testable import CoreKit

/// Spec c8fa126c, T-L-05 / T-L-06 / T-L-07.
///
/// Every test builds its OWN `Container` and calls `assemble` on it directly,
/// rather than going through `DI.configure`, which replaces the process-global
/// `Container.default`: a process-global plus parallel Swift Testing is a latent
/// race ([[a-process-global-test-override-plus-parallel-swift-testing-is-a-latent-race]]).
@Suite("CoreKitPlatformAssembly")
struct CoreKitPlatformAssemblyTests {
    private func makeSUT(
        environment: DIEnvironment = .production,
        subsystem: String = "io.shikki.corekit.tests"
    ) -> Container {
        let container = Container(name: "PlatformAssemblyTests")
        CoreKitPlatformAssembly(subsystem: subsystem).assemble(container: container, environment: environment)
        return container
    }

    // MARK: - T-L-05 / T-L-06

    /// T-L-05 on Apple, T-L-06 elsewhere — ONE test, because the whole point of
    /// the capability is that the call site is the same and only the registered
    /// type differs. Two tests would be two code paths again.
    @Test("the registered logger is the one the compilation target has (T-L-05, T-L-06)")
    func registersThePlatformLogger() throws {
        let container = makeSUT()
        let logger = try container.resolve((any LoggingProviding).self)

        #if canImport(os)
            #expect(logger is OSLogLogger, "Apple must get os.Logger, got \(type(of: logger))")
        #else
            #expect(logger is SwiftLogLogger, "off Apple must get swift-log, got \(type(of: logger))")
        #endif
    }

    @Test("the registered logger accepts every level and category without trapping")
    func theRegisteredLoggerIsCallableAcrossTheWholeVocabulary() throws {
        let logger = try makeSUT().resolve((any LoggingProviding).self)
        for level in LogLevel.allCases {
            for category in LogCategory.allCases {
                logger.log(level, category: category, message: "ratchet probe", privacy: .private)
            }
        }
        #expect(LogLevel.allCases.count == 7)
        #expect(LogCategory.allCases.count == 13, "AppLog had 13 categories; BR-L-07 keeps the count")
    }

    @Test("reachability and capacity resolve to the target's implementation")
    func registersThePlatformReachabilityAndProber() throws {
        let container = makeSUT()
        let reach = try container.resolve((any ReachabilityProviding).self)
        let prober = try container.resolve((any DeviceCapacityProbing).self)

        #if canImport(Network)
            #expect(reach is NWPathReachability, "got \(type(of: reach))")
        #else
            #expect(reach is GetifaddrsReachability, "got \(type(of: reach))")
        #endif

        #if canImport(Darwin)
            #expect(prober is PlatformCapacityProber, "got \(type(of: prober))")
        #else
            #expect(prober is ProcMeminfoCapacityProber, "got \(type(of: prober))")
        #endif
    }

    // MARK: - T-L-07

    @Test("a container with no platform assembly refuses, it does not default (T-L-07)")
    func anUnregisteredCapabilityIsANamedFailure() {
        let bare = Container(name: "NoPlatformAssembly")

        #expect(throws: ContainerError.self) {
            _ = try bare.resolve((any LoggingProviding).self)
        }
        #expect(throws: ContainerError.self) {
            _ = try bare.resolve((any ReachabilityProviding).self)
        }
        #expect(throws: ContainerError.self) {
            _ = try bare.resolve((any DeviceCapacityProbing).self)
        }
        #expect(bare.resolveOptional((any LoggingProviding).self) == nil)
    }

    @Test("the mock environment registers the same capabilities, never nothing")
    func mockEnvironmentStillRegisters() throws {
        let container = makeSUT(environment: .mock)
        #expect(throws: Never.self) { _ = try container.resolve((any LoggingProviding).self) }
        #expect(throws: Never.self) { _ = try container.resolve((any ReachabilityProviding).self) }
        #expect(throws: Never.self) { _ = try container.resolve((any DeviceCapacityProbing).self) }
    }

    // MARK: - the facade and the capability are ONE logger (BR-L-07)

    @Test("assembling installs the resolved provider into the AppLog facade")
    func theFacadeAndTheCapabilityAreTheSameLogger() throws {
        let container = makeSUT(subsystem: "io.shikki.facade.tests")
        let resolved = try container.resolve((any LoggingProviding).self)
        #expect(type(of: AppLog.provider) == type(of: resolved),
                "AppLog must forward to the registered provider, not keep its seed")
        // The old spelling still compiles and still reaches a provider.
        AppLog.cache.debug("facade still routes")
        #expect(AppLog.cache.category == .cache)
        #expect(AppLog.touchCursor.category.rawValue == "touch-cursor",
                "the os_log category string is part of the contract (BR-L-05)")
    }
}

/// Spec c8fa126c BR-L-05, measured. Seeding ``AppLog/provider`` with
/// ``SwiftLogLogger`` compiled, passed every other test, and silently moved
/// every Apple consumer that never configures DI from the unified log to
/// stdout. This suite pins the seed itself, separately from the assembly, so a
/// future edit to the seed cannot repeat it.
@Suite("AppLog's seed is the platform's own logger")
struct AppLogSeedTests {
    @Test("the facade's default provider is the same choice the assembly registers")
    func theSeedIsThePlatformDefault() {
        let seeded = CoreKitPlatformDefaults.makeLogger(subsystem: "io.shikki.seed.tests")
        #if canImport(os)
            #expect(seeded is OSLogLogger, "Apple's default must stay os.Logger, got \(type(of: seeded))")
        #else
            #expect(seeded is SwiftLogLogger, "off Apple the default is swift-log, got \(type(of: seeded))")
        #endif
    }

    @Test("every platform default is constructible on this target")
    func everyDefaultIsConstructible() {
        _ = CoreKitPlatformDefaults.makeLogger(subsystem: "io.shikki.seed.tests")
        _ = CoreKitPlatformDefaults.makeReachability()
        _ = CoreKitPlatformDefaults.makeCapacityProber()
        #expect(Bool(true), "a default that cannot be built is an absent capability (BR-L-06)")
    }
}
