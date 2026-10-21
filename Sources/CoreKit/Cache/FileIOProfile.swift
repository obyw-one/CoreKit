//
//  FileIOProfile.swift
//  CoreKit
//
//  Created 2026-10-16 — upstream addition for shikki resource-layer W0
//  (decision 913790a1).
//

import Foundation

// MARK: - FileIOProfile

/// Write-path profile for ``CacheRepository``.
///
/// The profile controls how bytes are committed to disk and whether
/// concurrent writers from different processes are serialised.
///
/// ### Choosing a profile
///
/// | Scenario | Use |
/// |---|---|
/// | In-process cache, crash-atomicity desired (default) | `.atomic` |
/// | In-process cache, no ordering guarantee needed | `.plain` |
/// | Daemon + kernel racing on the same file | `.durable` |
/// | On-device Tier-1 bridge, WabiSabi persistent store | `.durable` |
///
/// ### Backward compatibility
///
/// ``CacheRepository`` defaults to `.atomic`, which is EXACTLY the previous
/// `Data.write(options: .atomic)` behavior. Existing call sites are
/// unaffected.
public enum FileIOProfile: Sendable, Equatable {

    // MARK: Cases

    /// Straight `Data.write` with no special options.
    ///
    /// Suitable for scratch or transient data where neither crash-atomicity
    /// nor cross-process exclusion is required.
    case plain

    /// Write-to-temp-file then atomic rename via `Data.write(options: .atomic)`.
    ///
    /// Single-process crash-safe. **This is the default** and matches
    /// every pre-existing ``CacheRepository`` call site exactly — no
    /// behavior change for existing consumers.
    case atomic

    /// Cross-process durable write (Darwin).
    ///
    /// Steps performed on every `save`:
    ///
    /// 1. Acquires an exclusive POSIX `flock(LOCK_EX)` on a sibling lock
    ///    file (`.<name>.lock`), blocking until the lock is available.
    /// 2. Writes bytes to a per-PID temp file alongside the target.
    /// 3. Calls `fcntl(F_FULLFSYNC)` on the temp file for power-loss safety.
    /// 4. Atomically renames temp → target while holding the lock.
    /// 5. Releases the lock when the lock file descriptor closes.
    ///
    /// Use when two or more processes (e.g. a daemon and a kernel worker)
    /// may write the same cache file concurrently.
    case durable
}
