import CoreKitTestSupport
import Foundation
import Testing

@testable import CoreKit

/// The shrink-only ratchet on `@unchecked` `Sendable` (spec 610d808a, BR-LS-05).
///
/// Operator ruling 2026-11-16: the count "may only go down". This suite is that
/// rule, measured on CoreKit's own tree.
///
/// WHY A COUNT **AND** AN ALLOWANCE LIST, not just a count: a bare baseline
/// number tells a later reader nothing about which conformances are legitimate,
/// so the first person who needs one raises the number and the ratchet becomes
/// decoration ([[ratchet-baselines-are-contracts-never-raise-one-to-fit-your-change]]).
/// Every surviving conformance is named here WITH its reason, so adding one is a
/// visible, reviewable act and removing one is a one-line diff.
///
/// WHY ZERO IS NOT THE TARGET: three shapes cannot be made checked-`Sendable`
/// by moving state into a lock — an `open class` (a subclass can add
/// unsynchronised state), a Foundation protocol conformance that requires
/// `NSObject`, and a type storing a non-`Sendable` Apple object for its
/// lifetime. A rule the tree must violate by design is an allowance list
/// wearing a ratchet's name, which is the exact error caught in spec c8fa126c's
/// portability work.
///
/// WHY THE NEEDLE IS ASSEMBLED FROM PIECES: this file would otherwise match its
/// own scan. A source-text ratchet that counts itself reports a number nobody
/// can reconcile ([[a-source-text-ratchet-must-measure-the-thing-it-names]]).
@Suite("@unchecked Sendable is shrink-only (spec 610d808a)")
struct UncheckedSendableRatchetTests {

    // MARK: - The contract

    /// Every conformance allowed to survive, with the reason it cannot be
    /// converted. Only the three admitted reasons of BR-LS-06 belong here.
    ///
    /// To retire an entry: convert the type, delete the line, lower `baseline`.
    static let allowances: [String: String] = [
        "Sources/CoreKit/DI/Container.swift":
            """
            `open class`. A subclass can add unsynchronised mutable state, so the \
            superclass cannot promise checked Sendable on its behalf. Measured \
            2026-11-16: NOTHING in the fleet actually subclasses Container \
            (zero hits for `class X: Container` across CoreKit, shikki, NetKit, \
            shikki-plugin-api, shi-qa, shikki-client, BackendKit), so making it \
            `final` would retire this allowance at the cost of a nominal source \
            break. That is a separate decision, not this epic's.
            """,
    ]

    /// The measured count on 2026-11-16, after the spec-610d808a W1 conversions
    /// took CoreKit from 13 real conformances to 1. It may only go down.
    static let baseline = 1

    // MARK: - Rules

    @Test("the count of @unchecked Sendable conformances never exceeds the baseline")
    func countIsAtOrBelowBaseline() throws {
        let found = try Self.conformances()
        #expect(
            found.count <= Self.baseline,
            """
            \(found.count) @unchecked Sendable conformances, baseline \(Self.baseline).
            A baseline is a contract: convert the type, or — if it is one of the three
            admitted irreducible shapes — add it to `allowances` WITH its reason in the
            same commit, and say so in the PR body.
            New or unexpected:
            \(found.map { "  \($0.path):\($0.line)  \($0.text)" }.joined(separator: "\n"))
            """
        )
    }

    @Test("every surviving conformance is a named allowance, not an unexplained one")
    func everySurvivorIsNamed() throws {
        let unexplained = try Self.conformances().filter { Self.allowances[$0.path] == nil }
        #expect(
            unexplained.isEmpty,
            """
            these conformances survive with no recorded reason:
            \(unexplained.map { "  \($0.path):\($0.line)  \($0.text)" }.joined(separator: "\n"))
            """
        )
    }

    /// A stale allowance is as bad as a missing one: it keeps the baseline
    /// propped up for a file that no longer has the problem, which is how a
    /// ratchet silently stops ratcheting.
    @Test("no allowance names a path that no longer has the conformance")
    func noStaleAllowance() throws {
        let root = try Self.packageRoot()
        let live = Set(try Self.conformances().map(\.path))
        for (path, _) in Self.allowances {
            #expect(
                FileManager.default.fileExists(atPath: root.appending(path: path).path),
                "allowance names \(path), which does not exist — delete the entry"
            )
            #expect(
                live.contains(path),
                "allowance for \(path) is STALE: the conformance is gone. Delete the entry and lower `baseline`."
            )
        }
    }

    /// BR-LS-02: `LockedState` is the fleet's one lock box. A second one —
    /// however it is spelled — is the drift this epic deletes, and CoreKit had
    /// two of them (`LockedBox` in ContainerTests, and a local `Mutex<T>` in
    /// FileIOProfileTests that shadowed the stdlib primitive's name).
    @Test("no second lock box is declared anywhere in the package")
    func noSecondLockBox() throws {
        let canonical = "Sources/CoreKit/Concurrency/LockedState.swift"
        let names = ["LockedState", "LockedBox", "Locked", "Protected", "Guarded", "Synchronized", "Mutex"]
        let pattern = try NSRegularExpression(
            pattern: "(final\\s+)?(class|struct|actor)\\s+(" + names.joined(separator: "|") + ")\\b"
        )

        var offenders: [String] = []
        for file in try Self.swiftFiles() where file.relative != canonical {
            for (number, line) in file.lines where !Self.isComment(line) {
                let range = NSRange(line.startIndex..., in: line)
                if pattern.firstMatch(in: line, range: range) != nil {
                    offenders.append("\(file.relative):\(number)  \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            """
            a second lock box is declared. CoreKit ships exactly one, at \(canonical);
            everything else consumes it.
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// The primitive has to hold its own end of the bargain, or the whole epic
    /// is a rename: `LockedState` must be `Sendable` **without** the escape
    /// hatch it exists to remove.
    @Test("LockedState itself claims Sendable without @unchecked")
    func theprimitiveIsCheckedSendable() throws {
        let root = try Self.packageRoot()
        let source = try String(
            contentsOf: root.appending(path: "Sources/CoreKit/Concurrency/LockedState.swift"),
            encoding: .utf8
        )
        let declaration = source
            .split(separator: "\n")
            // Matched WITHOUT the `class` keyword: with it, this string literal is
            // itself a declaration-shaped line and rule 2 below matched this very
            // file. Same self-match trap as `needle`, one line further down.
            .first { $0.contains("LockedState<State: Sendable>") }
        let line = try #require(declaration, "LockedState's declaration has moved or gone")
        #expect(line.contains(": Sendable"), "LockedState must declare Sendable: \(line)")
        #expect(
            !line.contains(Self.needle),
            "LockedState may not use the escape hatch it exists to replace: \(line)"
        )
    }

    // MARK: - Scanning

    /// Assembled, never written whole, so this file does not match its own scan.
    static let needle = "@un" + "checked Sendable"

    struct Conformance {
        let path: String
        let line: Int
        let text: String
    }

    /// A conformance is a NON-COMMENT line that names the attribute after a
    /// colon — i.e. in an inheritance clause. The comment filter is the half
    /// that matters: CoreKit's sources discuss `@unchecked` in prose, and an
    /// unanchored grep counts those, which is precisely the defect that put a
    /// wrong tally into spec c8fa126c
    /// ([[a-spec-table-count-comes-from-an-anchored-directive-grep-2026-11-16]]).
    static func conformances() throws -> [Conformance] {
        var found: [Conformance] = []
        for file in try swiftFiles() {
            for (number, line) in file.lines where !isComment(line) {
                guard let hit = line.range(of: needle), line[line.startIndex..<hit.lowerBound].contains(":") else { continue }
                found.append(
                    Conformance(
                        path: file.relative,
                        line: number,
                        text: line.trimmingCharacters(in: .whitespaces)
                    )
                )
            }
        }
        return found
    }

    static func isComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")
    }

    struct SwiftFile {
        let relative: String
        let lines: [(Int, String)]
    }

    static func swiftFiles() throws -> [SwiftFile] {
        let root = try packageRoot()
        var files: [SwiftFile] = []
        for directory in ["Sources", "Tests"] {
            let base = root.appending(path: directory, directoryHint: .isDirectory)
            guard let walker = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                let text = try String(contentsOf: url, encoding: .utf8)
                files.append(
                    SwiftFile(
                        relative: relative,
                        lines: Array(text.split(separator: "\n", omittingEmptySubsequences: false)
                            .map(String.init)
                            .enumerated()
                            .map { ($0.offset + 1, $0.element) })
                    )
                )
            }
        }
        #expect(!files.isEmpty, "scanned no Swift files — the walk is broken, not the tree clean")
        return files
    }

    /// CoreKit's own primitive, not a hand-rolled walk.
    ///
    /// The first version of this suite located the package by taking this
    /// file's own source path and stripping parent directories in a loop until
    /// it found `Package.swift`. That tripped `CountedDepthWalkRatchet` (T-08),
    /// which bans that pairing fleet-wide (BR-PATH-02) because a hand-counted
    /// walk silently changes what it points at the moment the file moves.
    /// `TestPackagePaths` is the one legitimate implementation, marked as the
    /// path SSoT primitive and exempt for that reason.
    ///
    /// The prose above deliberately avoids spelling the two banned calls: the
    /// scanner keys on raw substrings and does NOT skip comments, so naming
    /// them here would make this file a hit all over again.
    static func packageRoot() throws -> URL {
        TestPackagePaths.packageRoot()
    }
}
