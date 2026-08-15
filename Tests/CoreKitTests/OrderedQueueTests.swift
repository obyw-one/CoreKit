@testable import CoreKit
import XCTest

/// OrderedQueue — the stable priority-queue mechanics extracted from shikki
/// (#1529 review): ascending-key dequeue, FIFO within equal keys, run-to-run
/// determinism, batch/element-wise equivalence.
final class OrderedQueueTests: XCTestCase {

    struct Key: Comparable, Sendable, Equatable {
        let rank: Int
        let stamp: Date
        let slug: String

        static func < (lhs: Key, rhs: Key) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.stamp != rhs.stamp { return lhs.stamp < rhs.stamp }
            return lhs.slug < rhs.slug
        }
    }

    private func key(_ rank: Int, _ offset: TimeInterval = 0, _ slug: String = "s") -> Key {
        Key(rank: rank, stamp: Date(timeIntervalSince1970: 1_000 + offset), slug: slug)
    }

    func test_dequeuesInAscendingKeyOrder() {
        var q = OrderedQueue<Key, String>()
        q.enqueue("p2", key: key(2))
        q.enqueue("p0", key: key(0))
        q.enqueue("p1", key: key(1))
        XCTAssertEqual(q.drain(), ["p0", "p1", "p2"])
    }

    func test_equalKeysDequeueInArrivalOrder() {
        var q = OrderedQueue<Key, String>()
        let k = key(1)
        q.enqueue("first", key: k)
        q.enqueue("second", key: k)
        q.enqueue("third", key: k)
        XCTAssertEqual(q.drain(), ["first", "second", "third"])
    }

    func test_olderStampDequeuesFirstWithinRank() {
        var q = OrderedQueue<Key, String>()
        q.enqueue("fresh", key: key(1, 60))
        q.enqueue("stale", key: key(1, 0))
        XCTAssertEqual(q.dequeue(), "stale")
        XCTAssertEqual(q.dequeue(), "fresh")
    }

    func test_batchEnqueueMatchesElementWise() {
        let items: [(String, Key)] = [
            ("a", key(1)), ("b", key(0)), ("c", key(1)), ("d", key(0, 5)),
        ]
        var elementWise = OrderedQueue<Key, String>()
        for (payload, k) in items { elementWise.enqueue(payload, key: k) }

        var batch = OrderedQueue<Key, String>()
        let keyed = Dictionary(uniqueKeysWithValues: items.map { ($0.0, $0.1) })
        batch.enqueue(contentsOf: items.map(\.0)) { keyed[$0]! }

        XCTAssertEqual(elementWise.drain(), batch.drain())
    }

    func test_determinismAcrossRuns() {
        // Same input sequence → identical dequeue order, twice over.
        func build() -> [String] {
            var q = OrderedQueue<Key, String>()
            q.enqueue("x", key: key(2, 0, "x"))
            q.enqueue("y", key: key(2, 0, "x"))  // fully equal key → arrival breaks
            q.enqueue("z", key: key(0))
            return q.drain()
        }
        XCTAssertEqual(build(), build())
        XCTAssertEqual(build(), ["z", "x", "y"])
    }

    func test_peekDoesNotConsume() {
        var q = OrderedQueue<Key, String>()
        q.enqueue("only", key: key(0))
        XCTAssertEqual(q.peek(), "only")
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q.dequeue(), "only")
        XCTAssertNil(q.peek())
    }

    func test_dequeueOnEmptyReturnsNil() {
        var q = OrderedQueue<Key, String>()
        XCTAssertNil(q.dequeue())
        XCTAssertTrue(q.isEmpty)
    }

    func test_orderedPayloadsIsNonConsumingSnapshot() {
        var q = OrderedQueue<Key, String>()
        q.enqueue("b", key: key(1))
        q.enqueue("a", key: key(0))
        XCTAssertEqual(q.orderedPayloads, ["a", "b"])
        XCTAssertEqual(q.count, 2)
    }
}
