//
//  CacheEntryEngine.swift
//  CoreKit
//
//  What a cache does to a model on its way to and from bytes — identical over
//  every backing, so that swapping the backing changes where the bytes live
//  and nothing about how they are read. Extracted from `CacheRepository`
//  (spec d3f8a1b2, BR-RP-11) so the synchronous and the asynchronous facade
//  share one definition of the envelope, the TTL rule and the entry naming.
//

import Foundation

// MARK: - Container envelope

struct CacheContainerModel<ModelType: Codable & Sendable>: Codable, Sendable {
    var timestamp: TimeInterval
    var modelType: String
    var body: String // Serialized ref of ModelType data
    var invalideTime: InvalidateTime
    var readCount: Int

    nonisolated init(data: ModelType, invalideTime: InvalidateTime, readCount: Int = 0, timestamp: TimeInterval = Date().timeIntervalSince1970) throws {
        do {
            let serializedData = try JSONEncoder().encode(data)
            let serializedStr = String(data: serializedData, encoding: .utf8)
            guard let serialized = serializedStr, !serialized.isEmpty else {
                throw CacheRepositoryError.encodedError
            }

            self.timestamp = timestamp
            self.modelType = String(describing: type(of: data.self))
            self.body = serialized
            self.invalideTime = invalideTime
            self.readCount = readCount
        } catch let error as CacheRepositoryError {
            throw error
        } catch {
            AppLog.cache.error("Cache error: \(error)")
            throw CacheRepositoryError.cannotCreateCache
        }
    }

    nonisolated func decoded() throws -> ModelType {
        guard let data = body.data(using: .utf8) else {
            throw CacheRepositoryError.decodedError
        }
        return try JSONDecoder().decode(ModelType.self, from: data)
    }

    /// Explicit Codable implementation to prevent main actor isolation
    private enum CodingKeys: String, CodingKey {
        case timestamp
        case modelType
        case body
        case invalideTime
        case readCount
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        modelType = try container.decode(String.self, forKey: .modelType)
        body = try container.decode(String.self, forKey: .body)
        invalideTime = try container.decode(InvalidateTime.self, forKey: .invalideTime)
        readCount = try container.decode(Int.self, forKey: .readCount)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(modelType, forKey: .modelType)
        try container.encode(body, forKey: .body)
        try container.encode(invalideTime, forKey: .invalideTime)
        try container.encode(readCount, forKey: .readCount)
    }
}

// MARK: - Decode outcome

/// What decoding an entry concluded.
enum CacheDecodeOutcome<Model: Sendable>: Sendable {
    /// The entry is valid and decoded.
    case value(Model)
    /// The entry is past its TTL while the network is reachable: the caller
    /// invalidates it and reports that no cache is available.
    case expired
}

// MARK: - CacheEntryEngine

/// Naming, envelope, codec and TTL for one cache — pure, no storage access.
struct CacheEntryEngine<Model: Codable & Sendable>: Sendable {

    let name: String
    let invalidateTime: InvalidateTime
    let envelope: EnvelopeMode
    let naming: FileNaming
    let codec: CacheCodec

    // MARK: Naming

    /// The backing entry name for `id`.
    func entry(for id: String) -> String {
        switch naming {
        case .legacy:
            name + "-" + id + ".cache"
        case .bareId(let ext):
            ext.map { "\(id).\($0)" } ?? id
        case .custom(let derive):
            derive(name, id)
        }
    }

    /// Whether `entry` is one `list()` enumerates for this cache: the legacy
    /// `<name>-<id>.cache` shape (the only shape that can be inverted).
    func isListable(_ entry: String) -> Bool {
        entry.hasPrefix(name + "-") && entry.hasSuffix(".cache")
    }

    // MARK: Encode

    func encode(_ model: Model) throws -> Data {
        switch envelope {
        case .container:
            let container = try CacheContainerModel(data: model, invalideTime: invalidateTime)
            return try JSONEncoder().encode(container)
        case .raw:
            return try codec.makeEncoder().encode(model)
        case .rawString:
            guard let text = model as? String else {
                AppLog.cache.error("Cache save error: .rawString requires ModelType == String, got \(Model.self)")
                throw CacheRepositoryError.encodedError
            }
            return Data(text.utf8)
        }
    }

    // MARK: Decode

    /// Decodes `blob` under the envelope and TTL rules.
    ///
    /// - Parameter hasNetwork: when `false`, an expired entry is still served
    ///   (offline support); when `true`, it reports ``CacheDecodeOutcome/expired``.
    func decode(_ blob: CacheBlob, hasNetwork: Bool) throws -> CacheDecodeOutcome<Model> {
        switch envelope {
        case .container:
            do {
                var container = try JSONDecoder().decode(CacheContainerModel<Model>.self, from: blob.data)
                guard containerIsValid(&container, hasNetwork: hasNetwork) else { return .expired }
                let model = try container.decoded()
                AppLog.cache.debug("CacheRepository: get local data (.container)")
                return .value(model)
            } catch let error as CacheRepositoryError {
                throw error
            } catch {
                AppLog.cache.error("Data in cache not decoded: \(error)")
                throw CacheRepositoryError.decodedError
            }

        case .raw:
            // .raw has no in-file timestamp — TTL is honored via the entry's modification date.
            if rawIsExpired(blob), hasNetwork { return .expired }
            do {
                let model = try codec.makeDecoder().decode(Model.self, from: blob.data)
                AppLog.cache.debug("CacheRepository: get local data (.raw)")
                return .value(model)
            } catch {
                AppLog.cache.error("Data in cache not decoded (.raw): \(error)")
                throw CacheRepositoryError.decodedError
            }

        case .rawString:
            // Verbatim UTF-8 — same modification-date TTL rule as .raw.
            if rawIsExpired(blob), hasNetwork { return .expired }
            guard let text = String(data: blob.data, encoding: .utf8), let model = text as? Model else {
                AppLog.cache.error("Data in cache not decoded (.rawString requires ModelType == String, got \(Model.self))")
                throw CacheRepositoryError.decodedError
            }
            AppLog.cache.debug("CacheRepository: get local data (.rawString)")
            return .value(model)
        }
    }

    /// The model `list()` reports for `blob`, or `nil` when the entry is not a
    /// valid container (another envelope, a foreign file) or has expired.
    /// Listing never fails on a bad entry: it skips it and says why.
    func listedModel(from blob: CacheBlob, entry: String) -> Model? {
        do {
            var container = try JSONDecoder().decode(CacheContainerModel<Model>.self, from: blob.data)
            guard containerIsValid(&container, hasNetwork: true) else {
                AppLog.cache.debug("CacheRepository.list skipped expired entry \(entry)")
                return nil
            }
            return try container.decoded()
        } catch {
            AppLog.cache.debug("CacheRepository.list skipped undecodable entry \(entry): \(error)")
            return nil
        }
    }

    // MARK: TTL

    /// Checks if the container entry is valid based on TTL and network reachability.
    /// - Note: When offline (`hasNetwork` is `false`), expired cache is still considered valid
    ///         to support offline mode functionality.
    private func containerIsValid(_ container: inout CacheContainerModel<Model>, hasNetwork: Bool) -> Bool {
        // Never invalidate cache if configured as such
        if case .never = invalidateTime { return true }

        // Check if Time To Live is OK
        if case .inTime(let ttl) = invalidateTime {
            let isExpired = container.timestamp + ttl <= Date().timeIntervalSince1970

            // If cache is fresh, use it
            if !isExpired { return true }

            // Cache is expired - check network status for offline support
            // If offline, use expired cache anyway (offline mode)
            // If online, invalidate and let caller fetch fresh data
            return !hasNetwork
        }

        return false
    }

    /// TTL check for `.raw` / `.rawString` — the timestamp lives in the entry's
    /// modification date, not inside the payload (payload is the model itself).
    private func rawIsExpired(_ blob: CacheBlob) -> Bool {
        // `.never` never expires — regardless of age.
        if case .never = invalidateTime { return false }

        if case .inTime(let ttl) = invalidateTime {
            // Can't read the modification date → treat as fresh, don't destroy readable data.
            guard let modified = blob.modified else { return false }
            return modified.timeIntervalSince1970 + ttl <= Date().timeIntervalSince1970
        }

        return false
    }
}
