import CoreKitTestSupport
import Foundation
import Testing
@testable import CoreKit

/// Spec c8fa126c BR-L-04, T-L-03 and T-L-04 — and f1a7c3e8's T-02 before them.
///
/// The `CoreKit` product must stay free of Apple-only frameworks so it builds on
/// Linux, AND the per-target choice must stay in ONE place. Both halves are
/// source scans, which is why they are kagami ratchets in a test target rather
/// than product code
/// ([[source-scanning-ratchets-belong-in-kagami-never-in-the-product]]).
///
/// The exclusion is `Sources/CoreKit/Platform/` **by path subtree**, never a
/// filename list ([[a-ratchet-scopes-a-folder-subtree-never-a-filename-list]]):
/// a new file dropped beside `CoreKitPlatformAssembly.swift` is covered without
/// anyone editing this test, and a file moved out of the subtree is caught.
@Suite("CoreKit core portability ratchet")
struct CorePortabilityRatchetTests {
    /// Apple frameworks that have no Linux counterpart. `Darwin` is NOT here: it
    /// is one half of the `Darwin`/`Glibc`/`Musl` libc triple that every POSIX
    /// target has an arm of, so banning it would ban portability itself.
    /// `Metal`, `Security` and `CryptoKit` ARE here — each has a declared home
    /// (`Platform/Apple`, `CoreKitSecurity`, swift-crypto).
    private static let forbidden = [
        "SwiftUI", "Combine", "Network", "UIKit", "AppKit", "os", "Metal", "Security", "CryptoKit",
    ]

    /// The one subtree where a platform condition and an Apple import may appear:
    /// the DI assembly and the implementations it chooses between (BR-L-03).
    private static let platformSubtree = "Platform"

    // MARK: - T-L-04

    @Test("no Apple-only import in Sources/CoreKit outside Platform/, guarded or not (T-L-04)")
    func coreImportsAreLinuxClean() throws {
        let root = TestPackagePaths.sourcesRoot(ofModule: "CoreKit")
        let files = try Self.swiftFiles(under: root).filter { !Self.isInPlatformSubtree($0, root: root) }
        #expect(files.count > 10, "ratchet scanned too few files — locator drift?")

        var offenders: [String] = []
        for file in files {
            for (index, raw) in try Self.lines(of: file).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("import ") else { continue }
                let module = line.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
                if Self.forbidden.contains(module) {
                    offenders.append("\(Self.relative(file, root: root)):\(index + 1) import \(module)")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            """
            Apple-only imports in the portable CoreKit target: \(offenders).
            BR-L-02: declare the capability as a protocol here and put the \
            implementation in Sources/CoreKit/Platform/, registered by \
            CoreKitPlatformAssembly.
            """
        )
    }

    /// The tightening rev 3 asked for and f1a7c3e8's T-02 did not have: a
    /// *guarded* `import os` used to pass, because the old scan only counted
    /// unguarded ones. A guard is exactly how two code paths through one call
    /// site get in, so the guarded form is banned too — the test above makes no
    /// distinction, and this one pins the distinction's absence so a future
    /// "just guard it" edit cannot quietly restore it.
    @Test("a guarded Apple-only import is a violation too, not an exemption (T-L-04)")
    func guardedAppleImportIsStillAViolation() throws {
        let root = TestPackagePaths.sourcesRoot(ofModule: "CoreKit")
        let sample = """
        import Foundation
        #if canImport(os)
        import os
        #endif
        """
        let offenders = Self.appleImports(inLines: sample.components(separatedBy: .newlines))
        #expect(offenders == ["3 import os"], "the scan must not skip a guarded import")
        _ = root
    }

    // MARK: - T-L-03

    @Test("no platform condition in Sources/CoreKit outside Platform/ (T-L-03)")
    func platformConditionsLiveOnlyInThePlatformSubtree() throws {
        let root = TestPackagePaths.sourcesRoot(ofModule: "CoreKit")
        let files = try Self.swiftFiles(under: root).filter { !Self.isInPlatformSubtree($0, root: root) }

        var offenders: [String] = []
        for file in files {
            for (index, raw) in try Self.lines(of: file).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("#if") || line.hasPrefix("#elseif"), Self.isAppleCapabilityCondition(line) else { continue }
                offenders.append("\(Self.relative(file, root: root)):\(index + 1) \(line)")
            }
        }
        #expect(
            offenders.isEmpty,
            """
            Apple-capability conditions outside Sources/CoreKit/Platform/: \(offenders).
            BR-L-03: the per-target choice is made in CoreKitPlatformAssembly and nowhere else.
            """
        )
    }

    /// What T-L-03 does NOT ban, stated as a test so the allowance is a measured
    /// contract and not a reviewer's memory ([[a-source-text-ratchet-must-measure-the-thing-it-names]]):
    ///
    /// - `#if DEBUG` — a build configuration, not a platform.
    /// - `canImport(Darwin) || canImport(Glibc)` — the libc triple. Every POSIX
    ///   target has an arm, so it selects a spelling, not a capability.
    /// - `canImport(FoundationNetworking)` / `canImport(FoundationXML)` —
    ///   upstream Foundation's own split, not ours. The spec names this
    ///   explicitly as the one correct conditional import.
    /// - `os(Windows)` — a non-Apple target. Banning it would make the Windows
    ///   assessment unimplementable.
    @Test("the T-L-03 allowance is exactly libc, Foundation's own split, DEBUG and non-Apple targets")
    func conditionClassifierIsExact() {
        let banned = [
            "#if canImport(os)",
            "#if canImport(Network)",
            "#if canImport(SwiftUI)",
            "#if canImport(Metal)",
            "#if canImport(Security)",
            "#if os(macOS)",
            "#elseif os(iOS)",
            "#if os(macOS) || os(iOS)",
            "#if canImport(Darwin) && canImport(os)",
        ]
        for line in banned {
            #expect(Self.isAppleCapabilityCondition(line), "should be banned: \(line)")
        }

        let allowed = [
            "#if DEBUG",
            "#if canImport(Darwin)",
            "#if canImport(Glibc)",
            "#elseif canImport(Musl)",
            "#if canImport(Darwin) || canImport(Glibc)",
            "#if canImport(FoundationNetworking)",
            "#if canImport(FoundationXML)",
            "#if os(Windows)",
            "#if os(Linux)",
        ]
        for line in allowed {
            #expect(!Self.isAppleCapabilityCondition(line), "should be allowed: \(line)")
        }
    }

    // MARK: - the portable vocabulary still round-trips (f1a7c3e8 T-02)

    @Test("the core's interface-type vocabulary is platform-neutral (T-02)")
    func networkReachabilityStoreRoundTrips() async {
        await NetworkReachabilityStore.shared.update(.ethernet)
        #expect(await NetworkReachabilityStore.shared.interfaceType == .ethernet)
        await NetworkReachabilityStore.shared.update(nil)
        #expect(await NetworkReachabilityStore.shared.interfaceType == nil)
    }

    // MARK: - Scanner

    /// An Apple *capability* condition: it names an Apple-only framework through
    /// `canImport`, or an Apple OS through `os(...)`. `Darwin` alone is libc.
    static func isAppleCapabilityCondition(_ line: String) -> Bool {
        let appleFrameworks = forbidden.filter { $0 != "os" } + ["os"]
        for framework in appleFrameworks where line.contains("canImport(\(framework))") {
            return true
        }
        for osName in ["macOS", "iOS", "tvOS", "watchOS", "visionOS"] where line.contains("os(\(osName))") {
            return true
        }
        return false
    }

    static func appleImports(inLines lines: [String]) -> [String] {
        var out: [String] = []
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("import ") else { continue }
            let module = line.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
            if forbidden.contains(module) { out.append("\(index + 1) import \(module)") }
        }
        return out
    }

    private static func lines(of file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
    }

    private static func relative(_ file: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return file.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count))
    }

    private static func isInPlatformSubtree(_ file: URL, root: URL) -> Bool {
        relative(file, root: root)
            .split(separator: "/", omittingEmptySubsequences: true)
            .contains(Substring(platformSubtree))
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
