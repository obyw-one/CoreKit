//
//  AWSSignatureV4.swift
//  CoreKit
//
//  AWS Signature Version 4, the request signing every S3-compatible store
//  (Garage, MinIO, ...) accepts. Foundation and swift-crypto only.
//

import Crypto
import Foundation

// MARK: - S3Credentials

/// An access key and its secret. The secret is never printed, dumped or
/// logged: `description`, `debugDescription` and the reflection mirror all
/// leave it out.
public struct S3Credentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let accessKey: String
    fileprivate let secretKey: String

    public init(accessKey: String, secretKey: String) {
        self.accessKey = accessKey
        self.secretKey = secretKey
    }

    public var description: String { "S3Credentials(accessKey: \(accessKey), secretKey: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["accessKey": accessKey]) }
}

// MARK: - AWSSignatureV4

/// Signs a request with SigV4.
///
/// Pure: the date is passed in, so the same inputs always produce the same
/// signature, and the algorithm is checked against AWS's published
/// known-answer example in the test suite rather than trusted.
public struct AWSSignatureV4: Sendable {

    public let credentials: S3Credentials
    public let region: String
    public let service: String

    public init(credentials: S3Credentials, region: String, service: String) {
        self.credentials = credentials
        self.region = region
        self.service = service
    }

    // MARK: Signing

    /// A request as the signer sees it.
    public struct SignableRequest: Sendable {
        /// The HTTP method.
        public let method: String
        /// The already URI-encoded absolute path.
        public let canonicalURI: String
        /// The already canonical query (see ``AWSSignatureV4/canonicalQuery(_:)``).
        public let canonicalQuery: String
        /// Every header to sign, any case; the signer lowercases, trims and sorts them.
        public let headers: [String: String]
        /// The lowercase-hex SHA-256 of the body.
        public let payloadHash: String

        public init(
            method: String, canonicalURI: String, canonicalQuery: String,
            headers: [String: String], payloadHash: String
        ) {
            self.method = method
            self.canonicalURI = canonicalURI
            self.canonicalQuery = canonicalQuery
            self.headers = headers
            self.payloadHash = payloadHash
        }
    }

    /// The `Authorization` header value for `request`, signed at `date`.
    public func authorization(for request: SignableRequest, date: Date) -> String {
        let canonical = canonicalRequest(request)
        let stamp = Self.timestamp(date)
        let scope = credentialScope(date)
        let stringToSign = [Self.algorithm, stamp.dateTime, scope, ContentHash.sha256(canonical.text)]
            .joined(separator: Self.lineBreak)
        let signature = Self.hex(Self.hmac(key: signingKey(date), message: stringToSign))
        return "\(Self.algorithm) Credential=\(credentials.accessKey)\(PathVocabulary.wireSeparator)\(scope), "
            + "SignedHeaders=\(canonical.signedHeaders), Signature=\(signature)"
    }

    /// The canonical request string and the signed-header list (exposed for known-answer tests).
    func canonicalRequest(_ request: SignableRequest) -> (text: String, signedHeaders: String) {
        let headers = Self.normalize(request.headers)
        let signedHeaders = headers.map(\.name).joined(separator: Self.headerSeparator)
        let canonicalHeaders = headers.map { "\($0.name):\($0.value)" }.joined(separator: Self.lineBreak) + Self.lineBreak
        let text = [
            request.method, request.canonicalURI, request.canonicalQuery, canonicalHeaders, signedHeaders,
            request.payloadHash,
        ].joined(separator: Self.lineBreak)
        return (text, signedHeaders)
    }

    /// `<date>/<region>/<service>/aws4_request`.
    func credentialScope(_ date: Date) -> String {
        [Self.timestamp(date).date, region, service, Self.terminator].joined(separator: PathVocabulary.wireSeparator)
    }

    /// The derived signing key for `date`.
    func signingKey(_ date: Date) -> Data {
        let dateKey = Self.hmac(key: Data((Self.keyPrefix + credentials.secretKey).utf8), message: Self.timestamp(date).date)
        let regionKey = Self.hmac(key: dateKey, message: region)
        let serviceKey = Self.hmac(key: regionKey, message: service)
        return Self.hmac(key: serviceKey, message: Self.terminator)
    }

    // MARK: Canonicalisation

    /// `name=value` pairs, each side URI-encoded, sorted by encoded name then
    /// value, joined with `&`.
    public static func canonicalQuery(_ items: [(name: String, value: String)]) -> String {
        items
            .map { (name: encode($0.name), value: encode($0.value)) }
            .sorted { ($0.name, $0.value) < ($1.name, $1.value) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "&")
    }

    /// RFC 3986 percent-encoding as SigV4 specifies: unreserved characters
    /// (`A-Z a-z 0-9 - _ . ~`) pass through, everything else is `%XX` of its
    /// UTF-8 bytes in upper-case hex.
    public static func encode(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            if unreserved.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    // MARK: Private

    private static let algorithm = "AWS4-HMAC-SHA256"
    private static let terminator = "aws4_request"
    private static let keyPrefix = "AWS4"
    private static let lineBreak = "\n"
    private static let headerSeparator = ";"
    private static let unreserved: Set<UInt8> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".utf8)

    /// Lowercased names, trimmed values with inner runs of spaces collapsed, sorted by name.
    private static func normalize(_ headers: [String: String]) -> [(name: String, value: String)] {
        headers
            .map { (name: $0.key.lowercased(), value: collapseSpaces($0.value.trimmingCharacters(in: .whitespaces))) }
            .sorted { $0.name < $1.name }
    }

    private static func collapseSpaces(_ value: String) -> String {
        value.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    private static func timestamp(_ date: Date) -> (date: String, dateTime: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return (day, formatter.string(from: date))
    }

    private static func hmac(key: Data, message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
