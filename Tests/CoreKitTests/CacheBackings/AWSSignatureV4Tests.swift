import Foundation
import Testing

@testable import CoreKit

// MARK: - AWSSignatureV4Tests

/// The signer is checked against AWS's own published worked example (the IAM
/// `ListUsers` request in "Signature Version 4 signing process"), not against
/// itself: a self-consistent signer that is wrong would sign every request a
/// store then rejects, and nothing in-process would notice.
@Suite("AWSSignatureV4 — checked against the published known-answer example")
struct AWSSignatureV4Tests {

    private static let separator = PathVocabulary.wireSeparator

    /// AWS's documentation credentials.
    private static let accessKey = "AKIDEXAMPLE"
    private static let secretKey = ["wJalrXUtnFEMI", "K7MDENG+bPxRfiCYEXAMPLEKEY"].joined(separator: separator)

    private static func signer() -> AWSSignatureV4 {
        AWSSignatureV4(
            credentials: S3Credentials(accessKey: accessKey, secretKey: secretKey), region: "us-east-1", service: "iam")
    }

    /// 2015-08-30T12:36:00Z
    private static let signingDate = Date(timeIntervalSince1970: 1_440_938_160)

    private static let headers = [
        "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
        "Host": "iam.amazonaws.com",
        "X-Amz-Date": "20150830T123600Z",
    ]

    private static let emptyBodyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    private static func exampleRequest(query: String = "Action=ListUsers&Version=2010-05-08") -> AWSSignatureV4.SignableRequest {
        AWSSignatureV4.SignableRequest(
            method: "GET", canonicalURI: separator, canonicalQuery: query, headers: headers, payloadHash: emptyBodyHash)
    }

    @Test("the canonical request hashes to the documented value")
    func canonicalRequestHash() {
        let query = AWSSignatureV4.canonicalQuery([(name: "Version", value: "2010-05-08"), (name: "Action", value: "ListUsers")])
        #expect(query == "Action=ListUsers&Version=2010-05-08")
        let canonical = Self.signer().canonicalRequest(Self.exampleRequest(query: query))
        #expect(canonical.signedHeaders == "content-type;host;x-amz-date")
        #expect(ContentHash.sha256(canonical.text) == "f536975d06c0309214f805bb90ccff089219ecd68b2577efef23edd43b7e1a59")
    }

    @Test("the derived signing key matches the documented value")
    func signingKey() {
        let key = Self.signer().signingKey(Self.signingDate)
        #expect(key.map { String(format: "%02x", $0) }.joined()
            == "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9")
    }

    @Test("the credential scope is date, region, service and the terminator")
    func credentialScope() {
        #expect(Self.signer().credentialScope(Self.signingDate)
            == ["20150830", "us-east-1", "iam", "aws4_request"].joined(separator: Self.separator))
    }

    @Test("the Authorization header carries the documented signature")
    func authorization() {
        let value = Self.signer().authorization(for: Self.exampleRequest(), date: Self.signingDate)
        let scope = ["20150830", "us-east-1", "iam", "aws4_request"].joined(separator: Self.separator)
        #expect(value == "AWS4-HMAC-SHA256 Credential=\(Self.accessKey)\(Self.separator)\(scope), "
            + "SignedHeaders=content-type;host;x-amz-date, "
            + "Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")
    }

    @Test("header names and values are normalised before signing")
    func headerNormalisation() {
        func signed(_ headers: [String: String]) -> String {
            Self.signer().authorization(
                for: AWSSignatureV4.SignableRequest(
                    method: "GET", canonicalURI: Self.separator, canonicalQuery: "", headers: headers,
                    payloadHash: Self.emptyBodyHash),
                date: Self.signingDate)
        }
        #expect(signed(["a": "1 2", "B": "x"]) == signed(["A": "  1   2 ", "b": "x"]))
    }

    @Test("URI encoding keeps the unreserved set and upper-case percent-encodes the rest")
    func uriEncoding() {
        #expect(AWSSignatureV4.encode("AZaz09-_.~") == "AZaz09-_.~")
        #expect(AWSSignatureV4.encode("a b") == "a%20b")
        #expect(AWSSignatureV4.encode("é") == "%C3%A9")
        #expect(AWSSignatureV4.encode("a" + Self.separator + "b") == "a%2Fb")
        #expect(AWSSignatureV4.encode("a+b=c&d") == "a%2Bb%3Dc%26d")
    }

    @Test("canonical query sorts by encoded name, then value")
    func queryOrder() {
        let query = AWSSignatureV4.canonicalQuery([
            (name: "prefix", value: "a b"), (name: "list-type", value: "2"), (name: "a", value: "2"), (name: "a", value: "1"),
        ])
        #expect(query == "a=1&a=2&list-type=2&prefix=a%20b")
    }

    @Test("credentials never print their secret")
    func secretIsRedacted() {
        let credentials = S3Credentials(accessKey: "AK", secretKey: "very-secret-value")
        #expect(!credentials.description.contains("very-secret-value"))
        #expect(!credentials.debugDescription.contains("very-secret-value"))
        #expect(!String(reflecting: credentials).contains("very-secret-value"))
        var dumped = ""
        dump(credentials, to: &dumped)
        #expect(!dumped.contains("very-secret-value"))
        #expect(credentials.description.contains("AK"))
    }
}
