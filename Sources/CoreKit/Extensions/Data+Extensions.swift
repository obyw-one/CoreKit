//
//  Data+Extensions.swift
//  CoreKit
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 04/04/2024.
//  Review obyw-one/CoreKit#21: same rule as `Encodable` — errors surface,
//  the optional is a one-release shim for log one-liners.
//

import Foundation

public extension Data {
    /// Re-serialises JSON bytes pretty-printed. Throws `JSONSerialization`'s
    /// error when the bytes are not JSON instead of returning nil.
    func prettyJSON() throws -> String {
        let object = try JSONSerialization.jsonObject(with: self, options: [])
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        return try pretty.utf8Text()
    }

    @available(*, deprecated, message: "Swallows the JSON error — use `try prettyJSON()`, or `try? prettyJSON()` at a log site. Removed in CoreKit 0.10.0.")
    var prettyJson: String? {
        try? prettyJSON()
    }
}
