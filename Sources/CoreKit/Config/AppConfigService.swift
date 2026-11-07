//
//  AppConfigService.swift
//  CoreKit
//
//  Promoted from WabiSabi's `AppConfigService` (spec d3f8a1b2, BR-RP-13): fetch
//  the server-driven configuration once at launch, cache it, and run on the
//  cache — or on nothing — when the server cannot be reached. What WabiSabi
//  welded to PocketBase and to user messages is, here, an injected endpoint and
//  an injected repository.
//

import Foundation

// MARK: - BootstrapResult

/// What a ``AppConfigServiceProtocol/bootstrap()`` ended up with.
public enum BootstrapResult: Sendable, Equatable {
    /// The endpoint answered; the configuration is fresh and has been cached.
    case fetched
    /// The endpoint did not answer (the cause is logged); the cached configuration is in use.
    case usingCache
    /// Neither the endpoint nor the cache has a configuration; the app runs on local defaults.
    case unavailable
}

// MARK: - AppConfigServiceProtocol

/// Provides the server-driven configuration. Offline with an empty cache there
/// is none: ``currentConfig`` is `nil` and the app runs on its local defaults —
/// nothing is invented.
public protocol AppConfigServiceProtocol: Sendable {

    /// Loads the cached configuration (if none is in memory), then asks the
    /// endpoint. Call once at launch. Never throws: a failure is logged with its
    /// cause and reported in the result.
    @discardableResult
    func bootstrap() async -> BootstrapResult

    /// Loads the cached configuration into memory without asking the endpoint —
    /// for a launch that wants the last known configuration before the network.
    func restore() async

    /// The configuration in force (memory, from the endpoint or the cache), or `nil`.
    var currentConfig: AppConfig? { get }

    /// Why the app is blocked, if it is.
    var block: AppBlock? { get }
}

extension AppConfigServiceProtocol {
    /// Whether the app must not run (kill switch or maintenance).
    public var isBlocked: Bool { block != nil }
}

// MARK: - AppConfigService

/// The implementation: an endpoint to ask, a repository to remember in.
///
/// The repository is any `RepositoryProtocol<String, AppConfig>` — a
/// ``CacheRepository`` over a local folder, an ``AsyncCacheRepository`` over a
/// database or an object store — so where the last known configuration
/// survives is the host's decision, and its TTL is the repository's.
///
/// A configuration for ANOTHER app is refused, wherever it comes from: a kill
/// switch applied to the wrong app is an outage.
///
/// `@unchecked Sendable`: the only mutable state is `config`, and it is read
/// and written exclusively under `lock`.
public final class AppConfigService: AppConfigServiceProtocol, @unchecked Sendable {

    private let query: AppConfigQuery
    private let endpoint: any ConfigEndpoint
    private let cache: any RepositoryProtocol<String, AppConfig>

    private let lock = NSLock()
    private var config: AppConfig?

    public init(
        query: AppConfigQuery,
        endpoint: any ConfigEndpoint,
        cache: any RepositoryProtocol<String, AppConfig>
    ) {
        self.query = query
        self.endpoint = endpoint
        self.cache = cache
    }

    public var currentConfig: AppConfig? { lock.withLock { config } }

    public var block: AppBlock? { currentConfig?.block }

    public func restore() async {
        guard currentConfig == nil else { return }
        do {
            let cached = try await cache.get(query.storageKey)
            guard accepts(cached, from: "cache") else { return }
            lock.withLock { if config == nil { config = cached } }
            AppLog.config.debug("Loaded the app configuration from the cache")
        } catch let error as CacheRepositoryError {
            // A cold or expired cache is the normal first launch, not a failure.
            AppLog.config.debug("No cached app configuration: \(error)")
        } catch let error as RepositoryError {
            AppLog.config.debug("No cached app configuration: \(error)")
        } catch {
            AppLog.config.warning("The app configuration cache could not be read: \(error)")
        }
    }

    @discardableResult
    public func bootstrap() async -> BootstrapResult {
        await restore()
        do {
            let fetched = try await endpoint.fetchConfig(query)
            guard accepts(fetched, from: "endpoint") else { return fallbackResult() }
            lock.withLock { config = fetched }
            await remember(fetched)
            AppLog.config.info("Bootstrap succeeded from the endpoint")
            return .fetched
        } catch {
            AppLog.config.warning("Bootstrap could not reach the endpoint: \(error). Using the cache, if any.")
            return fallbackResult()
        }
    }

    // MARK: Private

    private func fallbackResult() -> BootstrapResult {
        currentConfig == nil ? .unavailable : .usingCache
    }

    private func remember(_ config: AppConfig) async {
        do {
            try await cache.save(query.storageKey, data: config)
        } catch {
            AppLog.config.warning("The app configuration could not be cached: \(error)")
        }
    }

    private func accepts(_ candidate: AppConfig, from source: String) -> Bool {
        guard candidate.appId == query.appId else {
            AppLog.config.error(
                "Ignored a configuration from the \(source): it is for app '\(candidate.appId)', this is '\(self.query.appId)'")
            return false
        }
        return true
    }
}

// MARK: - MockAppConfigService

/// A service holding a configuration set by the test: no endpoint, no cache.
/// By default there is no configuration at all — the app runs on its local
/// flags, exactly like a first launch offline.
///
/// `@unchecked Sendable`: `config` is only touched under `lock`.
public final class MockAppConfigService: AppConfigServiceProtocol, @unchecked Sendable {

    private let lock = NSLock()
    private var config: AppConfig?

    public init(config: AppConfig? = nil) {
        self.config = config
    }

    public var currentConfig: AppConfig? { lock.withLock { config } }
    public var block: AppBlock? { currentConfig?.block }

    public func setConfig(_ config: AppConfig?) {
        lock.withLock { self.config = config }
    }

    @discardableResult
    public func bootstrap() async -> BootstrapResult {
        currentConfig == nil ? .unavailable : .fetched
    }

    public func restore() async {}
}

// MARK: - ConfigBackedFeatureFlags

/// Feature flags whose server overrides come from the configuration service:
/// local defaults for the distribution, merged with whatever the service holds
/// right now. Read per call, so a bootstrap that completes later is seen by the
/// next resolution with nothing to refresh.
public struct ConfigBackedFeatureFlags<Key: FeatureFlagKey>: FeatureFlagResolving {

    private let distribution: Distribution
    private let service: any AppConfigServiceProtocol

    public init(distribution: Distribution, service: any AppConfigServiceProtocol) {
        self.distribution = distribution
        self.service = service
    }

    /// The flags as they stand now.
    public var flags: FeatureFlags<Key> {
        FeatureFlags<Key>(distribution: distribution).merged(with: service.currentConfig?.featureFlags)
    }

    public func resolve(_ flag: String) -> FlagResolution {
        flags.resolve(flag)
    }
}

// MARK: - DIAssemblyAppConfig

/// Registers the configuration service on the container.
public struct DIAssemblyAppConfig: DIAssembly {

    public let service: any AppConfigServiceProtocol

    public init(service: any AppConfigServiceProtocol) {
        self.service = service
    }

    public func assemble(container: Container, environment: DIEnvironment) {
        let service = service
        do {
            try container.register((any AppConfigServiceProtocol).self, scope: .cached) { _ in service }
        } catch {
            fatalError("DIAssemblyAppConfig: the container refused `AppConfigServiceProtocol` — \(error). Is the assembly listed twice?")
        }
    }
}
