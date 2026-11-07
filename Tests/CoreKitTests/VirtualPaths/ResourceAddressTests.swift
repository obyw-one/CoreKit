import CoreKit
import Foundation
import Testing

// MARK: - ResourceAddressTests

@Suite("ResourceAddress — bucket and key, with a node id (BR-RP-07, BR-RP-11)")
struct ResourceAddressTests {

    private static let slash = PathSeparator.posix.rawValue

    private static let validBuckets: [String] = ["evidence", "abc", "ev-1.archive", String(repeating: "a", count: 63)]

    private static let invalidBuckets: [String] = [
        "ab", String(repeating: "a", count: 64), "Evidence", "under_score", "-lead", "trail-", ".lead", "trail.",
        "a..b", "sp ace", ["a", "b"].joined(separator: slash), "",
    ]

    @Test("S3-compatible bucket names are accepted", arguments: ResourceAddressTests.validBuckets)
    func validBucket(_ raw: String) throws {
        #expect(try BucketName(raw).rawValue == raw)
    }

    @Test("names an S3-compatible store would refuse are refused", arguments: ResourceAddressTests.invalidBuckets)
    func invalidBucket(_ raw: String) {
        #expect(throws: VirtualPathError.invalidBucketName(raw)) { try BucketName(raw) }
    }

    @Test("a node id is a validated segment")
    func nodeIDValidated() throws {
        let hostile = [PathVocabulary.parentComponent, "x"].joined(separator: Self.slash)
        #expect(throws: VirtualPathError.self) { try NodeID(hostile) }
        #expect(NodeID("mac-studio").description == "mac-studio")
        let empty = String()
        #expect(throws: VirtualPathError.emptySegment) { try NodeID(empty) }
    }

    @Test("the key leads with the node, then the path; the wire form leads with the bucket")
    func rendering() throws {
        let address = ResourceAddress(
            bucket: "evidence", node: "mac-a", path: VirtualPath("kagami", "rows.json"))
        #expect(address.key == VirtualPath("mac-a", "kagami", "rows.json"))
        #expect(address.renderedKey() == ["mac-a", "kagami", "rows.json"].joined(separator: Self.slash))
        #expect(address.rendered() == ["evidence", "mac-a", "kagami", "rows.json"].joined(separator: Self.slash))
        #expect(address.description == address.rendered())
    }

    @Test("a rendered address parses back to the same address")
    func parseRoundTrip() throws {
        let address = ResourceAddress(
            bucket: "evidence", node: "mac-a", path: VirtualPath("kagami", "rows.json"))
        #expect(try ResourceAddress(parsing: address.rendered()) == address)
        let bare = ResourceAddress(bucket: "evidence", node: "mac-a", path: .empty)
        #expect(try ResourceAddress(parsing: bare.rendered()) == bare)
    }

    @Test("an address without a node is not an address")
    func parseNeedsNode() {
        #expect(throws: VirtualPathError.malformedWireForm("evidence")) { try ResourceAddress(parsing: "evidence") }
        #expect(throws: VirtualPathError.self) { try ResourceAddress(parsing: "") }
        let upper = ["Evidence", "mac-a"].joined(separator: Self.slash)
        #expect(throws: VirtualPathError.invalidBucketName("Evidence")) { try ResourceAddress(parsing: upper) }
    }

    @Test("two nodes writing one logical key land on two physical keys")
    func nodesDoNotCollide() {
        let path = VirtualPath("flows", "7f3a", "metadata.json")
        let keys = ["mac-a", "mac-b", "mac-c"].map {
            ResourceAddress(bucket: "evidence", node: NodeID(stringLiteral: $0), path: path).renderedKey()
        }
        #expect(Set(keys).count == 3)
    }

    @Test("Codable round-trips and validates")
    func codable() throws {
        let address = ResourceAddress(bucket: "evidence", node: "mac-a", path: VirtualPath("a.json"))
        let data = try JSONEncoder().encode(address)
        #expect(try JSONDecoder().decode(ResourceAddress.self, from: data) == address)
        let bad = Data("{\"bucket\":\"NOPE\",\"node\":\"n\",\"path\":[]}".utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ResourceAddress.self, from: bad) }
    }
}
