//
//  LockedState.swift
//  CoreKit
//
//  Mutable state behind a lock, `Sendable` BY CONSTRUCTION — the fleet's ONE
//  lock primitive (spec 610d808a, operator ruling 2026-11-16).
//
//  A class that holds mutable fields and a hand-rolled `NSLock` can only claim
//  `Sendable` with `@unchecked`, which asks the reader to trust the claim. Here
//  the lock IS the platform's own Sendable primitive and the state is a value
//  the class never exposes except through `withLock`, so the compiler checks
//  the claim instead.
//
//  WHY THIS IS NOT `Synchronization.Mutex` DIRECTLY, measured from the SDK's
//  own interface files on 2026-11-16:
//
//      Synchronization.Mutex       macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0
//      os.OSAllocatedUnfairLock    macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0
//
//  The fleet floor is macOS 14 / iOS 17. `Mutex` is ABOVE it; the unfair-lock
//  wrapper is BELOW it. Using `Mutex` directly would have forced every package
//  that declares iOS to iOS 18 — CoreKit, NetKit, AIKit, shikki-plugin-api and
//  shikki-client — for a primitive we can already have. `OSAllocatedUnfairLock`'s
//  plain `withLock` carries no `@available` of its own; only the `flags:`
//  overloads need macOS 15.
//
//  THE HONEST CAVEAT. `OSAllocatedUnfairLock` is itself declared
//  `@unchecked Sendable` inside the SDK. The `@unchecked` does not vanish from
//  the universe: it moves into one frozen, audited, Apple-owned struct, and the
//  fleet's ~647 unaudited ones become compiler-checked. That is the trade. This
//  type eliminates OURS, which is a different and smaller claim than
//  eliminating the construct.
//
//  Linux and the musl triples take the `Mutex` arm, where Swift 6 ships it with
//  no OS gate at all, so the static-SDK builds are unaffected either way.
//
//  Provenance: this is obyw-one/NetKit's `Sources/NetworkKit/LockedState.swift`,
//  shipped there since June and internal to a package most of the fleet does not
//  depend on. It is moved here, made public, and deleted there (spec 610d808a
//  BR-LS-02) rather than reinvented.
//

#if canImport(os)
    import os
#else
    import Synchronization
#endif

/// Mutable state guarded by a lock, safe to share across concurrency domains.
///
/// Reach for this when state is genuinely shared AND the call site is
/// synchronous. When the call site can be `async`, the house rule prefers an
/// `actor`, or returning the value instead of emitting it — a lock box on a
/// recorder is a symptom, not a design
/// ([[unchecked-sendable-on-a-recorder-is-a-symptom-make-the-callback-async]]).
///
/// ```swift
/// let hits = LockedState(0)
/// hits.withLock { $0 += 1 }
/// let total = hits.withLock { $0 }
/// ```
///
/// `State` must be `Sendable`: the value crosses domains every time it is read
/// out. A non-`Sendable` payload (`[any Error]`, a Foundation object) is a sign
/// the state should be reduced to something sendable first — collect
/// `String(describing:)` rather than the error, for instance.
public final class LockedState<State: Sendable>: Sendable {
    #if canImport(os)
        private let lock: OSAllocatedUnfairLock<State>
    #else
        private let lock: Mutex<State>
    #endif

    public init(_ initialState: State) {
        #if canImport(os)
            lock = OSAllocatedUnfairLock(initialState: initialState)
        #else
            lock = Mutex(initialState)
        #endif
    }

    /// Run `body` with exclusive access to the state.
    ///
    /// `rethrows`, so a non-throwing closure keeps a non-throwing call site and
    /// a throwing one propagates. Keep the body short: this is a spinlock on
    /// Apple platforms, and blocking inside it blocks every other holder.
    ///
    /// Never call `await` inside the body — there is no suspension point to be
    /// had, and a synchronous wait inside a lock held across an await is how a
    /// cooperative pool wedges
    /// ([[sync-subprocess-from-async-wedges-the-runtime]]).
    @discardableResult
    public func withLock<Result: Sendable>(
        _ body: @Sendable (inout State) throws -> Result
    ) rethrows -> Result {
        try lock.withLock { try body(&$0) }
    }
}
