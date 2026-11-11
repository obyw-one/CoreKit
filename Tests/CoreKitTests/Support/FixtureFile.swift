import Foundation

/// A raw wire fixture of the CoreKit test target, loaded from the target's bundle: `Fixtures/` is a
/// declared resource in `Package.swift`, so a moved or renamed file fails the BUILD, and the test needs no checkout.
/// Raw JSON stays the DECODE fixture (a Codable model cannot test its own wire decoding); the encode half
/// is asserted next to it so a renamed coding key fails in both directions.
struct FixtureFile {
    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String { "fixture \(name) is not in the CoreKitTests resource bundle" }
    }

    static func url(_ name: String) throws -> URL {
        let file = URL(fileURLWithPath: name)
        guard let found = Bundle.module.url(forResource: file.deletingPathExtension().lastPathComponent, withExtension: file.pathExtension) else {
            throw Missing(name: name)
        }
        return found
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    private init() {}
}
