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
        packageRoot(fromFilePath: "\(testFile)")
    }

    /// Dynamic-path variant — takes a runtime `String`. Exists so a test can
    /// synthesize a nested fake tree in a temp dir and prove the marker walk
    /// resolves the SAME package root from files at different depths
    /// (spec one-path-resolution-ssot T-01).
    public static func packageRoot(fromFilePath path: String) -> URL {
        var dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        preconditionFailure("TestPackagePaths.packageRoot: no Package.swift above \(path)")
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
