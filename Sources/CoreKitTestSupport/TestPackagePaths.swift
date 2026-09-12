import Foundation

// MARK: - TestPackagePaths

/// The ONE way a test locates the package it belongs to (CoreKit #21 review:
/// "did we not need the same Path DI system we have in shikki … one SSoT for
/// this topic"). Mirrors `ShikkiTestPaths.packageRoot(fromTestFile:)` in
/// shikki (#1668 review: three ratchets each counted parent components from
/// `#filePath`; a moved test broke the count silently) and the marker-walk
/// `PathResolvers.searchUp(for:)` in shikki-plugin-api — this is the copy
/// every kit will consume once spec one-path-resolution-ssot lands; until
/// then it is the only `#filePath` walk CoreKit is allowed.
public enum TestPackagePaths {
    /// The nearest ancestor of `testFile` that carries `Package.swift`.
    public static func packageRoot(fromTestFile testFile: StaticString = #filePath) -> URL {
        var dir = URL(fileURLWithPath: "\(testFile)").deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        preconditionFailure("TestPackagePaths.packageRoot: no Package.swift above \(testFile)")
    }

    /// `<packageRoot>/Sources` for the package that owns `testFile`.
    public static func sourcesRoot(fromTestFile testFile: StaticString = #filePath) -> URL {
        packageRoot(fromTestFile: testFile).appendingPathComponent("Sources", isDirectory: true)
    }

    /// `<packageRoot>/Sources/<module>` — the tree a per-module ratchet scans.
    public static func sourcesRoot(ofModule module: String, fromTestFile testFile: StaticString = #filePath) -> URL {
        sourcesRoot(fromTestFile: testFile).appendingPathComponent(module, isDirectory: true)
    }
}
