import CoreKit
import Foundation
import Testing

// MARK: - S3ObjectStoreClientTests

@Suite("S3ObjectStoreClient — path-style, signed, injected (BR-RP-07)")
struct S3ObjectStoreClientTests {

    private static let separator = PathVocabulary.wireSeparator
    private static let bucket: BucketName = "evidence"

    private func makeSUT(
        pageSize: Int = 3, endpointPath: String? = nil
    ) throws -> (client: S3ObjectStoreClient, transport: FakeS3Transport) {
        let transport = FakeS3Transport(accessKey: BackingHarnesses.accessKey, host: BackingHarnesses.host, pageSize: pageSize)
        var components = URLComponents()
        components.scheme = "http"
        components.host = "store.example.test"
        components.port = 3900
        if let endpointPath { components.path = endpointPath }
        let client = try S3ObjectStoreClient(
            endpoint: try unwrap(components.url), region: "test-region",
            credentials: S3Credentials(accessKey: BackingHarnesses.accessKey, secretKey: "secret-never-on-the-wire"),
            transport: transport, clock: { Date(timeIntervalSince1970: 1_440_938_160) })
        return (client, transport)
    }

    private func key(_ parts: String...) -> String { parts.joined(separator: Self.separator) }

    @Test("put and get round-trip through a path-style URL")
    func putGetPathStyle() async throws {
        let (client, transport) = try makeSUT()
        try await client.put(Data("hello".utf8), key: key("mac-a", "rows.json"), in: Self.bucket)
        let object = try await client.get(key: key("mac-a", "rows.json"), in: Self.bucket)
        #expect(object?.data == Data("hello".utf8))
        #expect(object?.lastModified != nil)

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["PUT", "GET"])
        #expect(requests[0].url.path == Self.separator + key("evidence", "mac-a", "rows.json"))
        #expect(requests[0].url.host == "store.example.test")
        #expect(requests[0].url.port == 3900)
        #expect(await transport.violations.isEmpty)
    }

    @Test("a key that needs encoding is signed and sent in the encoded form")
    func encodedKey() async throws {
        let (client, transport) = try makeSUT()
        let awkward = key("mac-a", "id with space", "é+&.cache")
        try await client.put(Data("x".utf8), key: awkward, in: Self.bucket)
        #expect(try await client.get(key: awkward, in: Self.bucket)?.data == Data("x".utf8))
        let sent = await transport.requests[0].url.absoluteString
        #expect(sent.contains("id%20with%20space"))
        #expect(sent.contains("%C3%A9%2B%26.cache"))
        #expect(await transport.violations.isEmpty)
    }

    @Test("a missing object is nil and not an error; exists agrees")
    func missingIsNil() async throws {
        let (client, _) = try makeSUT()
        #expect(try await client.get(key: "nope", in: Self.bucket) == nil)
        #expect(try await !client.exists(key: "nope", in: Self.bucket))
        try await client.put(Data(), key: "present", in: Self.bucket)
        #expect(try await client.exists(key: "present", in: Self.bucket))
    }

    @Test("delete does not fail when there was nothing to delete, like the verb it models")
    func deleteIsIdempotent() async throws {
        let (client, _) = try makeSUT()
        try await client.put(Data("x".utf8), key: "k", in: Self.bucket)
        try await client.delete(key: "k", in: Self.bucket)
        try await client.delete(key: "k", in: Self.bucket)
        #expect(try await !client.exists(key: "k", in: Self.bucket))
    }

    @Test("listing follows continuation tokens across pages and filters by prefix")
    func listingPaginates() async throws {
        let (client, transport) = try makeSUT(pageSize: 2)
        for index in 0..<7 {
            try await client.put(Data("x".utf8), key: key("mac-a", "e\(index)"), in: Self.bucket)
        }
        try await client.put(Data("y".utf8), key: key("mac-b", "other"), in: Self.bucket)
        let listed = try await client.keys(withPrefix: key("mac-a", ""), in: Self.bucket)
        #expect(Set(listed) == Set((0..<7).map { key("mac-a", "e\($0)") }))
        #expect(listed.count == 7)
        let listRequests = await transport.requests.filter { $0.url.query?.contains("list-type=2") == true }
        #expect(listRequests.count == 4, "7 keys at 2 per page is 4 requests")
        #expect(listRequests.dropFirst().allSatisfy { $0.url.query?.contains("continuation-token=") == true })
        #expect(await transport.violations.isEmpty)
    }

    @Test("a key with characters XML escapes comes back intact")
    func listingDecodesXMLEntities() async throws {
        let (client, _) = try makeSUT()
        let tricky = key("mac-a", "a&b<c")
        try await client.put(Data("x".utf8), key: tricky, in: Self.bucket)
        #expect(try await client.keys(withPrefix: "mac-a", in: Self.bucket) == [tricky])
    }

    @Test("a refusal is a typed error carrying the store's code, never a nil")
    func refusalIsTyped() async throws {
        let transport = FakeS3Transport(accessKey: "SOMEONEELSE", host: BackingHarnesses.host)
        var components = URLComponents()
        components.scheme = "http"
        components.host = "store.example.test"
        components.port = 3900
        let client = try S3ObjectStoreClient(
            endpoint: try unwrap(components.url), region: "test-region",
            credentials: S3Credentials(accessKey: "WRONGKEY", secretKey: "s"), transport: transport, clock: { Date() })
        let error = await #expect(throws: S3ObjectStoreError.self) { try await client.put(Data(), key: "k", in: Self.bucket) }
        #expect(error == .requestFailed(operation: "put", status: 403, code: "AccessDenied"))
        let readError = await #expect(throws: S3ObjectStoreError.self) { _ = try await client.get(key: "k", in: Self.bucket) }
        #expect(readError == .requestFailed(operation: "get", status: 403, code: "AccessDenied"))
    }

    @Test("the secret never appears in a request")
    func secretNeverOnTheWire() async throws {
        let (client, transport) = try makeSUT()
        try await client.put(Data("payload".utf8), key: "k", in: Self.bucket)
        _ = try await client.keys(withPrefix: "", in: Self.bucket)
        for request in await transport.requests {
            let everything = request.url.absoluteString + request.headers.values.joined() + request.headers.keys.joined()
            #expect(!everything.contains("secret-never-on-the-wire"))
        }
    }

    @Test("an endpoint path prefix is kept in front of the bucket")
    func endpointPathPrefix() async throws {
        let (client, transport) = try makeSUT(endpointPath: Self.separator + "s3")
        try await client.put(Data("x".utf8), key: "k", in: Self.bucket)
        #expect(await transport.requests[0].url.path == Self.separator + key("s3", "evidence", "k"))
    }

    @Test("an endpoint without an http(s) scheme and a host is refused at construction")
    func endpointIsValidated() throws {
        let transport = FakeS3Transport(accessKey: "a", host: "h")
        let credentials = S3Credentials(accessKey: "a", secretKey: "s")
        let file = URL(fileURLWithPath: PathVocabulary.filesystemRoot)
        #expect(throws: S3ObjectStoreError.unsupportedEndpoint(file.absoluteString)) {
            try S3ObjectStoreClient(endpoint: file, region: "r", credentials: credentials, transport: transport, clock: { Date() })
        }
        var noHost = URLComponents()
        noHost.scheme = "https"
        let url = try unwrap(noHost.url)
        #expect(throws: S3ObjectStoreError.self) {
            try S3ObjectStoreClient(endpoint: url, region: "r", credentials: credentials, transport: transport, clock: { Date() })
        }
    }

    @Test("a truncated listing with no continuation token is reported, not looped on")
    func brokenPaginationIsReported() async throws {
        let transport = BrokenListingTransport()
        var components = URLComponents()
        components.scheme = "http"
        components.host = "store.example.test"
        let client = try S3ObjectStoreClient(
            endpoint: try unwrap(components.url), region: "r",
            credentials: S3Credentials(accessKey: "a", secretKey: "s"), transport: transport, clock: { Date() })
        await #expect(throws: S3ObjectStoreError.self) { _ = try await client.keys(withPrefix: "", in: Self.bucket) }
    }

    @Test("a body that is not XML is a malformed-response error")
    func malformedListing() async throws {
        let transport = BrokenListingTransport(body: "<<not xml")
        var components = URLComponents()
        components.scheme = "http"
        components.host = "store.example.test"
        let client = try S3ObjectStoreClient(
            endpoint: try unwrap(components.url), region: "r",
            credentials: S3Credentials(accessKey: "a", secretKey: "s"), transport: transport, clock: { Date() })
        await #expect(throws: S3ObjectStoreError.malformedResponse(
            operation: "list", detail: "the listing is not well-formed XML")) {
            _ = try await client.keys(withPrefix: "", in: Self.bucket)
        }
    }

    @Test("Last-Modified is parsed from the HTTP date")
    func lastModifiedParsed() async throws {
        let (client, transport) = try makeSUT()
        try await client.put(Data("x".utf8), key: "k", in: Self.bucket)
        let known = Date(timeIntervalSince1970: 1_700_000_000)
        await transport.setModified(known, bucket: "evidence", key: "k")
        let object = try await client.get(key: "k", in: Self.bucket)
        #expect(object?.lastModified == known)
    }
}

// MARK: - BrokenListingTransport

/// Answers every request with a 200 listing body that is wrong in one chosen way.
private struct BrokenListingTransport: S3Transport {
    var body = "<ListBucketResult><IsTruncated>true</IsTruncated><Contents><Key>k</Key></Contents></ListBucketResult>"

    func send(_ request: S3Request) async throws -> S3Response {
        S3Response(status: 200, headers: [:], body: Data(body.utf8))
    }
}
