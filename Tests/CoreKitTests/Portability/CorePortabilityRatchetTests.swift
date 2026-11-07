import CoreKitTestSupport
import Foundation
import Testing
@testable import CoreKit

/// T-02 (spec f1a7c3e8): the `CoreKit` product must stay free of Apple-only
/// frameworks so it builds on Linux. An unguarded `import SwiftUI`, `Combine`,
/// `Network`, `UIKit`, `AppKit` or `os` in `Sources/CoreKit/` fails here, on a
/// macOS run, before it can fail a server deploy. UI belongs in `CoreKitUI`.
@Suite("CoreKit core portability ratchet")
struct CorePortabilityRatchetTests {
    private static let forbidden = ["SwiftUI", "Combine", "Network", "UIKit", "AppKit", "os"]

    @Test("no unguarded Apple-only import in Sources/CoreKit (T-02)")
    func coreImportsAreLinuxClean() throws {
        let root = TestPackagePaths.sourcesRoot(ofModule: "CoreKit")
        let files = try Self.swiftFiles(under: root)
        #expect(files.count > 10, "ratchet scanned too few files — locator drift?")

        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            var guardDepth = 0
            for (index, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#if") { guardDepth += 1 }
                if line.hasPrefix("#endif") { guardDepth -= 1 }
                guard guardDepth == 0, line.hasPrefix("import ") else { continue }
                let module = line.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
                if Self.forbidden.contains(module) {
                    offenders.append("\(file.lastPathComponent):\(index + 1) import \(module)")
                }
            }
        }
        #expect(offenders.isEmpty, "Apple-only imports in the core product: \(offenders)")
    }

    @Test("the core's interface-type vocabulary is platform-neutral (T-02)")
    func networkReachabilityStoreRoundTrips() async {
        await NetworkReachabilityStore.shared.update(.ethernet)
        #expect(await NetworkReachabilityStore.shared.interfaceType == .ethernet)
        await NetworkReachabilityStore.shared.update(nil)
        #expect(await NetworkReachabilityStore.shared.interfaceType == nil)
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
