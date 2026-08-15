import Foundation

// MARK: - OrderedQueue

/// A stable, value-type priority queue: entries dequeue in ascending `Key`
/// order, and entries whose keys compare equal dequeue in ARRIVAL order.
///
/// Extracted from shikki (#1529 review): `ReportPriorityQueue` and the
/// validated-spec drainer's `DispatchOrderKey` ordering both re-implemented
/// the same "Comparable key + stable FIFO within equal keys" mechanics.
/// The KEY stays domain-owned (each consumer defines its own `Comparable`
/// ordering key — rank/enqueuedAt/tie-breaker or whatever its domain
/// needs); the QUEUE mechanics live here, once.
///
/// Determinism contract: for identical input sequences, `dequeue()` order is
/// identical across runs — equal keys are broken by a private monotonic
/// arrival counter, never by hash order or timing. `enqueue(contentsOf:)`
/// yields exactly the order of element-wise `enqueue(_:key:)`.
///
/// Not thread-safe by itself: it is a value type — wrap it in an actor when
/// shared across concurrency domains.
public struct OrderedQueue<Key: Comparable & Sendable, Payload: Sendable>: Sendable {

    // MARK: - Storage

    @usableFromInline
    struct Slot: Sendable {
        @usableFromInline let key: Key
        @usableFromInline let arrival: UInt64
        @usableFromInline let payload: Payload

        @usableFromInline
        init(key: Key, arrival: UInt64, payload: Payload) {
            self.key = key
            self.arrival = arrival
            self.payload = payload
        }

        /// Total order: key first, arrival breaks ties — the stability rule.
        @usableFromInline
        func precedes(_ other: Slot) -> Bool {
            if key < other.key { return true }
            if other.key < key { return false }
            return arrival < other.arrival
        }
    }

    @usableFromInline var slots: [Slot] = []
    @usableFromInline var arrivalCounter: UInt64 = 0

    public init() {}

    // MARK: - Inspection

    public var count: Int { slots.count }
    public var isEmpty: Bool { slots.isEmpty }

    /// The payload that would dequeue next, without removing it.
    public func peek() -> Payload? { slots.first?.payload }

    /// All payloads in dequeue order (non-consuming snapshot).
    public var orderedPayloads: [Payload] { slots.map(\.payload) }

    // MARK: - Mutation

    /// Insert one payload under its ordering key. O(log n) search +
    /// O(n) insertion — the queue favours simplicity and determinism over
    /// heap asymptotics; consumers measured so far hold dozens of entries,
    /// not millions.
    public mutating func enqueue(_ payload: Payload, key: Key) {
        let slot = Slot(key: key, arrival: arrivalCounter, payload: payload)
        arrivalCounter &+= 1

        // Binary search for the first existing slot that the new slot
        // precedes; equal keys land BEHIND existing ones (arrival order).
        var low = 0
        var high = slots.count
        while low < high {
            let mid = (low + high) / 2
            if slot.precedes(slots[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        slots.insert(slot, at: low)
    }

    /// Insert a sequence element-wise — guaranteed to match the order that
    /// individual `enqueue(_:key:)` calls on the same sequence would yield.
    public mutating func enqueue<S: Sequence>(
        contentsOf sequence: S,
        key: (S.Element) -> Key
    ) where S.Element == Payload {
        for element in sequence {
            enqueue(element, key: key(element))
        }
    }

    /// Remove and return the smallest-keyed, earliest-arrived payload.
    public mutating func dequeue() -> Payload? {
        guard !slots.isEmpty else { return nil }
        return slots.removeFirst().payload
    }

    /// Remove every entry, returning payloads in dequeue order.
    public mutating func drain() -> [Payload] {
        let all = slots.map(\.payload)
        slots.removeAll()
        return all
    }
}
