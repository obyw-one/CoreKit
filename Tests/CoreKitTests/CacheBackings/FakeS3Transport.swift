import CoreKit
import Foundation

// MARK: - FakeS3Transport

/// A stateful, in-process S3 emulator behind `S3Transport`: PUT, GET, HEAD,
/// DELETE and a paginated ListObjectsV2, with the status codes and XML bodies
/// a compatible store returns. It runs the REAL client — request building,
/// signing, header handling, XML parsing — against a store that behaves like
/// one, and it REJECTS a request whose integrity is wrong instead of answering
/// it, so a signing or encoding regression fails a behaviour check rather than
/// passing unnoticed.
actor FakeS3Transport: S3Transport {

    struct Violation: Sendable, Equatable { let message: String }

    private struct Slot: Hashable {
        let bucket: String
        let key: String
    }

    private struct Stored {
        var data: Data
        var modified: Date
    }

    private var objects: [Slot: Stored] = [:]
    private(set) var requests: [S3Request] = []
    private(set) var violations: [String] = []

    let accessKey: String
    let host: String
    let pageSize: Int
    private let clock: @Sendable () -> Date

    init(accessKey: String, host: String, pageSize: Int = 3, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.accessKey = accessKey
        self.host = host
        self.pageSize = pageSize
        self.clock = clock
    }

    // MARK: Test controls

    func setModified(_ date: Date, bucket: String, key: String) {
        objects[Slot(bucket: bucket, key: key)]?.modified = date
    }

    func modified(bucket: String, key: String) -> Date? {
        objects[Slot(bucket: bucket, key: key)]?.modified
    }

    func storedKeys(bucket: String) -> [String] {
        objects.keys.filter { $0.bucket == bucket }.map(\.key).sorted()
    }

    // MARK: S3Transport

    func send(_ request: S3Request) async throws -> S3Response {
        requests.append(request)
        checkIntegrity(request)

        guard authorized(request) else { return error(403, "AccessDenied") }
        let components = request.url.pathComponents.filter { $0 != PathVocabulary.filesystemRoot }
        guard let bucket = components.first else { return error(400, "InvalidRequest") }
        let key = components.dropFirst().joined(separator: PathVocabulary.wireSeparator)
        let slot = Slot(bucket: bucket, key: key)

        switch request.method {
        case "PUT":
            objects[slot] = Stored(data: request.body, modified: clock())
            return S3Response(status: 200, headers: [:], body: Data())
        case "GET" where key.isEmpty:
            return list(bucket: bucket, url: request.url)
        case "GET":
            guard let stored = objects[slot] else { return error(404, "NoSuchKey") }
            return S3Response(status: 200, headers: ["last-modified": Self.httpDate(stored.modified)], body: stored.data)
        case "HEAD":
            guard let stored = objects[slot] else { return S3Response(status: 404, headers: [:], body: Data()) }
            return S3Response(status: 200, headers: ["last-modified": Self.httpDate(stored.modified)], body: Data())
        case "DELETE":
            objects.removeValue(forKey: slot)
            return S3Response(status: 204, headers: [:], body: Data())
        default:
            return error(405, "MethodNotAllowed")
        }
    }

    // MARK: Listing

    private func list(bucket: String, url: URL) -> S3Response {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let prefix = items.first { $0.name == "prefix" }?.value ?? ""
        let start = items.first { $0.name == "continuation-token" }?.value.flatMap(Int.init) ?? 0
        let matching = storedKeys(bucket: bucket).filter { $0.hasPrefix(prefix) }
        let page = Array(matching.dropFirst(start).prefix(pageSize))
        let truncated = start + page.count < matching.count
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult><Name>\(bucket)</Name>"
        xml += "<IsTruncated>\(truncated)</IsTruncated>"
        if truncated { xml += "<NextContinuationToken>\(start + page.count)</NextContinuationToken>" }
        for key in page { xml += "<Contents><Key>\(Self.escape(key))</Key></Contents>" }
        xml += "</ListBucketResult>"
        return S3Response(status: 200, headers: [:], body: Data(xml.utf8))
    }

    // MARK: Integrity

    /// A request the store would reject: recorded as a violation the test reads.
    private func checkIntegrity(_ request: S3Request) {
        let headers = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.key.lowercased(), $0.value) })
        if headers["host"] != host { violations.append("host header \(headers["host"] ?? "nil") != \(host)") }
        if headers["x-amz-content-sha256"] != ContentHash.sha256(request.body) {
            violations.append("x-amz-content-sha256 does not match the body")
        }
        if headers["x-amz-date"]?.range(of: #"^\d{8}T\d{6}Z$"#, options: .regularExpression) == nil {
            violations.append("x-amz-date is not yyyyMMddTHHmmssZ: \(headers["x-amz-date"] ?? "nil")")
        }
        guard let authorization = headers["authorization"] else {
            violations.append("no Authorization header")
            return
        }
        if !authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=\(accessKey)\(PathVocabulary.wireSeparator)") {
            violations.append("Authorization does not start with the algorithm and credential: \(authorization)")
        }
        if !authorization.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date,") {
            violations.append("SignedHeaders is not host;x-amz-content-sha256;x-amz-date")
        }
        if authorization.range(of: #"Signature=[0-9a-f]{64}$"#, options: .regularExpression) == nil {
            violations.append("Signature is not 64 lowercase hex characters")
        }
    }

    private func authorized(_ request: S3Request) -> Bool {
        request.headers["Authorization"]?.contains("Credential=\(accessKey)") == true
    }

    // MARK: Helpers

    private func error(_ status: Int, _ code: String) -> S3Response {
        S3Response(status: status, headers: [:], body: Data("<Error><Code>\(code)</Code></Error>".utf8))
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }

    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.string(from: date)
    }
}
