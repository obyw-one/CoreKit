import Crypto
import Foundation

// MARK: - ContentHash

/// The fleet's ONE content-hashing surface (shi-qa rev-2 W1, 2026-08-07).
///
/// Every shi-plugin that needs content addressing (kagami sidecar hashes,
/// cache keys, spec sha-pins) consumes this — never CryptoKit/Crypto
/// directly — so hash algorithm and encoding stay a single decision.
/// Backed by swift-crypto: identical bytes on Darwin, Linux, Windows.
///
/// Output format: lowercase hex SHA-256, 64 characters. This matches the
/// sidecar format kagami's ContentHasher already emitted (parity pinned
/// by shi-qa's `ContentHashUpstreamParityTests`), so adopting this surface
/// never invalidates existing caches.
public enum ContentHash {

    /// SHA-256 of in-memory bytes, lowercase hex.
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of a UTF-8 string, lowercase hex.
    public static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }

    /// Streaming SHA-256 of a file, lowercase hex — constant memory for
    /// arbitrarily large inputs (module-cache shards, media, bundles).
    ///
    /// - Parameter chunkSize: read granularity; default 1 MiB.
    public static func sha256(contentsOf url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = Incremental()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(chunk)
        }
        return hasher.finalizeHex()
    }

    // MARK: - Incremental

    /// Multi-input SHA-256 fold with the same output contract (lowercase
    /// hex) — for callers hashing composite structures (directory trees,
    /// path+bytes manifests) where the digest spans many updates.
    /// Extracted for shi-qa's tree hasher (cache-SSoT W2, 2026-08-07) so
    /// no consumer needs a direct Crypto import for fold semantics.
    public struct Incremental: Sendable {
        private var hasher = SHA256()

        public init() {}

        /// Fold `data` into the running digest.
        public mutating func update(_ data: Data) {
            hasher.update(data: data)
        }

        /// Fold a UTF-8 string into the running digest.
        public mutating func update(_ string: String) {
            hasher.update(data: Data(string.utf8))
        }

        /// Finish and render lowercase hex. Consumes the receiver's state
        /// conceptually — call once.
        public func finalizeHex() -> String {
            hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}
