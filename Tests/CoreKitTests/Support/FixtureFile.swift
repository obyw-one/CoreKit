import CoreKitTestSupport
import Foundation

/// A raw wire fixture of the CoreKit test target, loaded by URL from `Tests/CoreKitTests/Fixtures/`.
/// Raw JSON stays the DECODE fixture (a Codable model cannot test its own wire decoding); the encode half
/// is asserted next to it so a renamed coding key fails in both directions.
enum FixtureFile {
    static func url(_ name: String) -> URL {
        TestPackagePaths.packageRoot()
            .appending(path: "Tests", directoryHint: .isDirectory)
            .appending(path: "CoreKitTests", directoryHint: .isDirectory)
            .appending(path: "Fixtures", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .notDirectory)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }
}
