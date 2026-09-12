//
//  Encodable+Extensions.swift
//  CoreKit
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 04/04/2024.
//  Review obyw-one/CoreKit#21: the optional getters swallowed the encoding
//  error; the throwing functions are the API, the optionals are a one-release
//  shim for log one-liners (`try?` at the call site says so explicitly).
//

import Foundation

/// JSON bytes that are not UTF-8 text — thrown instead of hidden behind `nil`.
public enum JSONTextError: Error, Equatable {
    case notUTF8
}

extension Data {
    /// UTF-8 text or a thrown error — never a silent lossy decode.
    func utf8Text() throws -> String {
        guard let text = String(bytes: self, encoding: .utf8) else { throw JSONTextError.notUTF8 }
        return text
    }
}

public extension Encodable {
    /// Pretty-printed JSON. Throws the encoder's error instead of hiding it.
    func prettyJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        return try encoder.encode(self).utf8Text()
    }

    /// Compact JSON without escaped slashes. Throws the encoder's error.
    func compactJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return try encoder.encode(self).utf8Text()
    }

    @available(*, deprecated, message: "Swallows the encoding error — use `try prettyJSON()`, or `try? prettyJSON()` at a log site. Removed in CoreKit 0.10.0.")
    var prettyJson: String? {
        try? prettyJSON()
    }

    @available(
        *,
        deprecated,
        message: "Swallows the encoding error — use `try compactJSON()`, or `try? compactJSON()` at a log site. Removed in CoreKit 0.10.0."
    )
    var lessPrettyJson: String? {
        try? compactJSON()
    }
}
