//
//  S3ObjectStoreClient.swift
//  CoreKit
//
//  An S3-compatible ObjectStoreClient built from Foundation and swift-crypto
//  alone (spec d3f8a1b2, BR-RP-07): path-style requests signed with
//  SigV4, so a self-hosted store such as Garage works with no SDK and no new
//  dependency.
//

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - Transport

/// An HTTP request in the terms this client needs, free of any networking type.
public struct S3Request: Sendable, Equatable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data

    public init(method: String, url: URL, headers: [String: String], body: Data) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct S3Response: Sendable, Equatable {
    public let status: Int
    /// Header names lowercased.
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Sends one request. The seam that keeps this client free of a networking
/// stack: ``URLSessionS3Transport`` is the Foundation one, NetKit can supply its
/// own, and a test supplies a fake.
public protocol S3Transport: Sendable {
    func send(_ request: S3Request) async throws -> S3Response
}

// MARK: - Errors

public enum S3ObjectStoreError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// The store answered with a status this operation does not accept.
    case requestFailed(operation: String, status: Int, code: String?)
    /// The store answered 2xx with a body or header this client cannot read.
    case malformedResponse(operation: String, detail: String)
    /// The endpoint is not an http(s) URL with a host.
    case unsupportedEndpoint(String)

    public var description: String {
        switch self {
        case .requestFailed(let operation, let status, let code):
            "S3 \(operation) failed with status \(status)" + (code.map { " (\($0))" } ?? "")
        case .malformedResponse(let operation, let detail):
            "S3 \(operation) returned a response this client cannot read: \(detail)"
        case .unsupportedEndpoint(let endpoint):
            "S3 endpoint '\(endpoint)' is not an http(s) URL with a host"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - S3ObjectStoreClient

/// Put, get, exists, delete and list against an S3-compatible endpoint,
/// path-style (`<endpoint>/<bucket>/<key>`), which is what a self-hosted store
/// serves without wildcard DNS.
///
/// Everything environment-specific is injected: the endpoint, the region the
/// store signs for, the credentials, the transport and the clock. Nothing is
/// defaulted, because a default endpoint is a request sent somewhere nobody
/// chose.
public struct S3ObjectStoreClient: ObjectStoreClient {

    public let endpoint: URL
    public let region: String
    private let signer: AWSSignatureV4
    private let transport: any S3Transport
    private let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - endpoint: the store's base URL, scheme and host (and port, and an
    ///     optional path prefix).
    ///   - region: the region the store signs for.
    ///   - credentials: the access key pair.
    ///   - transport: how a request is sent.
    ///   - clock: the signing time.
    public init(
        endpoint: URL,
        region: String,
        credentials: S3Credentials,
        transport: any S3Transport,
        clock: @escaping @Sendable () -> Date
    ) throws(S3ObjectStoreError) {
        guard let scheme = endpoint.scheme?.lowercased(), Self.schemes.contains(scheme), endpoint.host != nil else {
            throw .unsupportedEndpoint(endpoint.absoluteString)
        }
        self.endpoint = endpoint
        self.region = region
        signer = AWSSignatureV4(credentials: credentials, region: region, service: Self.service)
        self.transport = transport
        self.clock = clock
    }

    // MARK: ObjectStoreClient

    public func put(_ data: Data, key: String, in bucket: BucketName) async throws {
        let response = try await send("PUT", bucket: bucket, key: key, body: data)
        try require(response, in: "put", accepting: [200])
    }

    public func get(key: String, in bucket: BucketName) async throws -> ObjectStoreObject? {
        let response = try await send("GET", bucket: bucket, key: key)
        if response.status == Self.notFound { return nil }
        try require(response, in: "get", accepting: [200])
        return ObjectStoreObject(data: response.body, lastModified: Self.lastModified(of: response))
    }

    public func exists(key: String, in bucket: BucketName) async throws -> Bool {
        let response = try await send("HEAD", bucket: bucket, key: key)
        if response.status == Self.notFound { return false }
        try require(response, in: "exists", accepting: [200])
        return true
    }

    public func delete(key: String, in bucket: BucketName) async throws {
        let response = try await send("DELETE", bucket: bucket, key: key)
        // S3 answers 204 whether or not the object existed; a 404 is the same outcome.
        try require(response, in: "delete", accepting: [200, 204, Self.notFound])
    }

    public func keys(withPrefix prefix: String, in bucket: BucketName) async throws -> [String] {
        var collected: [String] = []
        var token: String?
        repeat {
            var query = [(name: "list-type", value: "2"), (name: "prefix", value: prefix)]
            if let token { query.append((name: "continuation-token", value: token)) }
            let response = try await send("GET", bucket: bucket, key: nil, query: query)
            try require(response, in: "list", accepting: [200])
            let page = try Self.parseListing(response.body)
            collected += page.keys
            token = page.isTruncated ? page.nextToken : nil
            if page.isTruncated, page.nextToken == nil {
                throw S3ObjectStoreError.malformedResponse(operation: "list", detail: "truncated listing without a continuation token")
            }
        } while token != nil
        return collected
    }

    // MARK: Request building

    private static let service = "s3"
    private static let schemes: Set<String> = ["http", "https"]
    private static let notFound = 404

    private func send(
        _ method: String, bucket: BucketName, key: String?,
        query: [(name: String, value: String)] = [], body: Data = Data()
    ) async throws -> S3Response {
        let segments = endpointSegments + [bucket.rawValue] + (key.map(Self.keySegments) ?? [])
        let canonicalURI = PathVocabulary.wireSeparator
            + segments.map(AWSSignatureV4.encode).joined(separator: PathVocabulary.wireSeparator)
        let canonicalQuery = AWSSignatureV4.canonicalQuery(query)

        var components = URLComponents()
        components.scheme = endpoint.scheme
        components.host = endpoint.host
        components.port = endpoint.port
        components.percentEncodedPath = canonicalURI
        if !query.isEmpty { components.percentEncodedQuery = canonicalQuery }
        guard let url = components.url else {
            throw S3ObjectStoreError.unsupportedEndpoint(endpoint.absoluteString)
        }

        let now = clock()
        let payloadHash = ContentHash.sha256(body)
        var headers = [
            Self.hostHeader: hostValue(),
            Self.contentHashHeader: payloadHash,
            Self.dateHeader: Self.amzDate(now),
        ]
        headers[Self.authorizationHeader] = signer.authorization(
            for: AWSSignatureV4.SignableRequest(
                method: method, canonicalURI: canonicalURI, canonicalQuery: canonicalQuery,
                headers: headers, payloadHash: payloadHash),
            date: now)
        return try await transport.send(S3Request(method: method, url: url, headers: headers, body: body))
    }

    private static let hostHeader = "host"
    private static let contentHashHeader = "x-amz-content-sha256"
    private static let dateHeader = "x-amz-date"
    private static let authorizationHeader = "Authorization"

    private var endpointSegments: [String] {
        endpoint.pathComponents.filter { $0 != PathVocabulary.filesystemRoot }
    }

    private func hostValue() -> String {
        let host = endpoint.host ?? ""
        return endpoint.port.map { "\(host):\($0)" } ?? host
    }

    private static func keySegments(_ key: String) -> [String] {
        key.split(separator: PathVocabulary.wireSeparatorCharacter, omittingEmptySubsequences: true).map(String.init)
    }

    private static func amzDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    // MARK: Response handling

    private func require(_ response: S3Response, in operation: String, accepting statuses: [Int]) throws {
        guard statuses.contains(response.status) else {
            throw S3ObjectStoreError.requestFailed(
                operation: operation, status: response.status, code: Self.errorCode(in: response.body))
        }
    }

    private static func lastModified(of response: S3Response) -> Date? {
        guard let raw = response.headers["last-modified"] else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw)
    }

    /// The `<Code>` element of an S3 error body, if there is one.
    private static func errorCode(in body: Data) -> String? {
        guard !body.isEmpty else { return nil }
        let parser = ListingParser(wanted: ["Code"])
        return parser.parse(body) ? parser.collected["Code"]?.first : nil
    }

    private struct Listing {
        let keys: [String]
        let isTruncated: Bool
        let nextToken: String?
    }

    private static func parseListing(_ body: Data) throws -> Listing {
        let parser = ListingParser(wanted: ["Key", "IsTruncated", "NextContinuationToken"])
        guard parser.parse(body) else {
            throw S3ObjectStoreError.malformedResponse(operation: "list", detail: "the listing is not well-formed XML")
        }
        return Listing(
            keys: parser.collected["Key"] ?? [],
            isTruncated: parser.collected["IsTruncated"]?.first == "true",
            nextToken: parser.collected["NextContinuationToken"]?.first)
    }
}

// MARK: - ListingParser

/// Collects the text of the named elements, in document order. Local to one
/// call and never shared, so it needs no synchronisation.
private final class ListingParser: NSObject, XMLParserDelegate {
    private let wanted: Set<String>
    private(set) var collected: [String: [String]] = [:]
    private var current: String?
    private var text = ""

    init(wanted: Set<String>) {
        self.wanted = wanted
    }

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        current = wanted.contains(elementName) ? elementName : nil
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { text += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        if current == elementName { collected[elementName, default: []].append(text) }
        current = nil
        text = ""
    }
}

// MARK: - URLSessionS3Transport

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Foundation transport: `URLSession`.
public struct URLSessionS3Transport: S3Transport {

    private static let hostHeader = "host"
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: S3Request) async throws -> S3Response {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers where name.lowercased() != Self.hostHeader {
            // The URL loading system derives Host from the URL (which is what was signed).
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if !request.body.isEmpty { urlRequest.httpBody = request.body }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw S3ObjectStoreError.malformedResponse(operation: request.method, detail: "the response is not HTTP")
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return S3Response(status: http.statusCode, headers: headers, body: data)
    }
}
