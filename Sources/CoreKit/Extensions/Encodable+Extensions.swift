//
//  Encodable+Extensions.swift
//  CoreKit
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 04/04/2024.
//

import Foundation

public extension Encodable {
    var prettyJson: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var lessPrettyJson: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
