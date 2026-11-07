//
//  LocalFolderCacheBacking.swift
//  CoreKit
//
//  The default backing: one directory of files. Local, offline, and exactly the
//  bytes `CacheRepository` has always written there.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - LocalFolderCacheBacking

/// Entries as files in one directory.
///
/// The directory is created (with intermediate directories) when the backing
/// is made, as `CacheRepository` always did, and a failure to create it is
/// logged with its cause — the first write then reports the real error. An
/// entry name that would resolve OUTSIDE the directory (a `..` climb, a link
/// that leaves it) is refused (BR-RP-04); every name the fleet really uses is a
/// single file name or a nested path under it, and is unaffected.
///
/// The write is committed per ``FileIOProfile`` — `.atomic` by default, which
/// is exactly the previous behaviour.
public struct LocalFolderCacheBacking: SynchronousCacheBacking {

    public let directory: URL
    public let ioProfile: FileIOProfile

    public var fileIOProfile: FileIOProfile? { ioProfile }

    public init(directory: URL, ioProfile: FileIOProfile = .atomic) {
        self.directory = directory
        self.ioProfile = ioProfile
        // Best-effort mkdir -p. If this fails, a later write surfaces the underlying error.
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                AppLog.cache.warning("CacheRepository: could not create directory \(directory.path): \(error)")
            }
        }
    }

    // MARK: - SynchronousCacheBacking

    public func read(_ entry: String) throws -> CacheBlob? {
        let url = try location(of: entry)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return CacheBlob(data: data, modified: modificationDate(of: url))
    }

    public func write(_ data: Data, as entry: String) throws {
        let url = try location(of: entry)
        switch ioProfile {
        case .plain:
            try data.write(to: url)
        case .atomic:
            try data.write(to: url, options: .atomic)
        case .durable:
            try durableWrite(data, to: url, entry: entry)
        }
    }

    public func remove(_ entry: String) throws -> Bool {
        let url = try location(of: entry)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.removeItem(at: url)
        return true
    }

    public func contains(_ entry: String) throws -> Bool {
        FileManager.default.fileExists(atPath: try location(of: entry).path)
    }

    public func names() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).map(\.lastPathComponent)
    }

    // MARK: - Location

    /// The file for `entry`, contained in ``directory``.
    private func location(of entry: String) throws -> URL {
        let url = directory.appendingPathComponent(entry)
        // A single component cannot leave the directory, so the common case
        // pays for no filesystem walk.
        if Self.isSingleComponent(entry) { return url }
        guard PathContainment.isContained(url, in: directory) else {
            throw CacheBackingError.entryEscapesLocation(entry: entry)
        }
        return url
    }

    private static func isSingleComponent(_ entry: String) -> Bool {
        !entry.isEmpty && entry != PathVocabulary.currentComponent && entry != PathVocabulary.parentComponent
            && !PathSeparator.allCases.contains { entry.contains($0.rawValue) }
    }

    private func modificationDate(of url: URL) -> Date? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        } catch {
            // Unknown age reads as fresh (see `CacheBlob.modified`); say why.
            AppLog.cache.debug("CacheRepository: could not read the modification date of \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    // MARK: - Durable write

    /// Cross-process durable write: flock + temp-file + sync + rename.
    ///
    /// A sibling lock file (`.<filename>.lock`) is the exclusive-lock target so
    /// the lock stays valid across the rename of the data file; it is released
    /// when the fd closes. Sync is `F_FULLFSYNC` on Darwin, where plain `fsync`
    /// does not reach the media, and `fsync` elsewhere.
    private func durableWrite(_ data: Data, to fileURL: URL, entry: String) throws {
#if canImport(Darwin) || canImport(Glibc)
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        let lockPath = dir.appendingPathComponent(".\(fileURL.lastPathComponent).lock").path

        let lockFd = open(lockPath, O_CREAT | O_WRONLY, S_IRUSR | S_IWUSR)
        guard lockFd >= 0 else {
            throw CacheBackingError.ioFailed(operation: "open lock file", entry: entry, errnoCode: errno)
        }
        defer { close(lockFd) }   // releases the flock automatically

        // Blocks until no other process holds the lock.
        while flock(lockFd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw CacheBackingError.ioFailed(operation: "acquire lock", entry: entry, errnoCode: errno)
            }
        }

        // Write to a per-PID temp file alongside the target.
        let pid = ProcessInfo.processInfo.processIdentifier
        let tempURL = dir.appendingPathComponent(".\(fileURL.lastPathComponent).tmp\(pid)")
        defer { try? fm.removeItem(at: tempURL) }

        try data.write(to: tempURL)

        // Flush to physical media (power-loss safety).
        let tempFd = open(tempURL.path, O_RDONLY)
        guard tempFd >= 0 else {
            throw CacheBackingError.ioFailed(operation: "reopen temp file", entry: entry, errnoCode: errno)
        }
        defer { close(tempFd) }
#if canImport(Darwin)
        // Not every filesystem supports F_FULLFSYNC; fsync is the best it offers.
        let synced = fcntl(tempFd, F_FULLFSYNC) != -1 || fsync(tempFd) == 0
#else
        let synced = fsync(tempFd) == 0
#endif
        guard synced else {
            throw CacheBackingError.ioFailed(operation: "sync", entry: entry, errnoCode: errno)
        }

        // Atomic rename while holding the lock — POSIX rename(2) replaces the
        // target in one operation.
        guard rename(tempURL.path, fileURL.path) == 0 else {
            throw CacheBackingError.ioFailed(operation: "rename", entry: entry, errnoCode: errno)
        }

        // The rename lives in the directory entry, so sync that too. Best effort:
        // some filesystems refuse fsync on a directory.
        let dirFd = open(dir.path, O_RDONLY)
        if dirFd >= 0 {
            _ = fsync(dirFd)
            close(dirFd)
        }
#else
        // Not built or tested here (Windows, musl): NOT cross-process safe.
        AppLog.cache.warning("Durable write: no flock on this platform — falling back to atomic write")
        try data.write(to: fileURL, options: .atomic)
#endif
    }
}

// MARK: - InMemoryCacheBacking

/// Entries held in memory: the backing for tests, for session-scoped caches,
/// and for a consumer that must not touch the disk.
///
/// `@unchecked Sendable` is deliberate and complete: every mutable member is
/// reached only while holding `lock`, and the clock is a `@Sendable` closure.
public final class InMemoryCacheBacking: SynchronousCacheBacking, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [String: CacheBlob] = [:]
    private let clock: @Sendable () -> Date

    /// - Parameter clock: where "modified" comes from; inject a fake to age
    ///   entries deterministically.
    public init(clock: @escaping @Sendable () -> Date) {
        self.clock = clock
    }

    public convenience init() {
        self.init(clock: { Date() })
    }

    public func read(_ entry: String) throws -> CacheBlob? {
        lock.withLock { storage[entry] }
    }

    public func write(_ data: Data, as entry: String) throws {
        let now = clock()
        lock.withLock { storage[entry] = CacheBlob(data: data, modified: now) }
    }

    public func remove(_ entry: String) throws -> Bool {
        lock.withLock { storage.removeValue(forKey: entry) != nil }
    }

    public func contains(_ entry: String) throws -> Bool {
        lock.withLock { storage[entry] != nil }
    }

    public func names() throws -> [String] {
        lock.withLock { Array(storage.keys) }
    }

    /// Sets when `entry` was last written — to model an old entry. `false`
    /// when there is no such entry.
    @discardableResult
    public func setModified(_ date: Date?, for entry: String) -> Bool {
        lock.withLock {
            guard let blob = storage[entry] else { return false }
            storage[entry] = CacheBlob(data: blob.data, modified: date)
            return true
        }
    }
}
