import Foundation
import Testing
@testable import CoreKit

/// Spec c8fa126c W1. The portable half of the logging capability: the
/// vocabulary, and a recording double that proves the facade's defaults.
/// One captured log record. At file scope rather than nested inside
/// `Recorder`, which is itself nested in the suite: three levels trips the
/// fleet's `nesting` rule and the type is useful to any other double.
struct LogRecord: Equatable, Sendable {
    let level: LogLevel
    let category: LogCategory
    let message: String
    let privacy: LogPrivacy
}

@Suite("Logging capability")
struct LoggingCapabilityTests {
    /// A ``LoggingProviding`` that keeps what it was handed, IN ORDER.
    ///
    /// The ordering is the whole difficulty: the protocol's `log` is
    /// synchronous and `Sendable`, so a double that hands each record to an
    /// actor in a detached `Task` records them in whatever order the pool runs
    /// them — measured, and it is not the call order. An
    /// `AsyncStream.Continuation` is the one primitive that is both
    /// `Sendable` and synchronous AND preserves yield order, so the double
    /// needs no lock and no `@unchecked Sendable`
    /// ([[unchecked-sendable-on-a-recorder-is-a-symptom-make-the-callback-async]]).
    struct Recorder: LoggingProviding {
        let stream: AsyncStream<LogRecord>
        private let continuation: AsyncStream<LogRecord>.Continuation

        init() {
            (stream, continuation) = AsyncStream.makeStream(of: LogRecord.self)
        }

        func log(_ level: LogLevel, category: LogCategory, message: String, privacy: LogPrivacy) {
            continuation.yield(LogRecord(level: level, category: category, message: message, privacy: privacy))
        }

        /// The next `count` records, in call order. Finishes the stream so a
        /// test can never hang waiting for a record that was never emitted —
        /// it gets a short list and a failed expectation instead.
        func take(_ count: Int) async -> [LogRecord] {
            var out: [LogRecord] = []
            guard count > 0 else { continuation.finish(); return out }
            for await record in stream {
                out.append(record)
                if out.count == count { break }
            }
            continuation.finish()
            return out
        }
    }

    @Test("the level vocabulary is ordered and total")
    func levelsAreOrdered() {
        #expect(LogLevel.allCases == [.trace, .debug, .info, .notice, .warning, .error, .critical])
        #expect(LogLevel.trace < LogLevel.critical)
        #expect(LogLevel.warning < LogLevel.error)
        #expect(Set(LogLevel.allCases.map(\.severity)).count == LogLevel.allCases.count)
    }

    @Test("every category keeps the os_log string AppLog shipped (BR-L-05)")
    func categoriesKeepTheirStrings() {
        let expected = [
            "app", "auth", "navigation", "network", "tracking", "cache", "ui", "di", "config",
            "notification", "timer", "storekit", "touch-cursor",
        ]
        #expect(LogCategory.allCases.map(\.rawValue) == expected)
    }

    @Test("the convenience methods map to their own level")
    func conveniencesMapToLevels() async {
        let recorder = Recorder()
        recorder.trace("t")
        recorder.debug("d")
        recorder.info("i")
        recorder.notice("n")
        recorder.warning("w")
        recorder.error("e")
        recorder.critical("c")
        let records = await recorder.take(7)
        #expect(records.map(\.level) == [.trace, .debug, .info, .notice, .warning, .error, .critical])
        #expect(records.allSatisfy { $0.category == .app }, "the convenience default is .app")
        #expect(records.allSatisfy { $0.privacy == .private }, "the convenience default is .private")
    }

    @Test("the AppLog facade forwards category, level and the default privacy")
    func facadeForwards() async {
        let recorder = Recorder()
        let previous = AppLog.provider
        AppLog.provider = recorder
        defer { AppLog.provider = previous }

        AppLog.cache.error("Cache save error: boom")
        AppLog.di.debug("Container 'X' registrations:")
        AppLog.network.info("public please", privacy: .public)

        let records = await recorder.take(3)
        #expect(records.count == 3)
        #expect(records[0] == LogRecord(level: .error, category: .cache, message: "Cache save error: boom", privacy: .private))
        #expect(records[1].category == .di)
        #expect(records[1].level == .debug)
        #expect(records[2].privacy == .public)
    }

    @Test("swift-log redaction is off by default and on when the host asks")
    func swiftLogRedaction() {
        #expect(SwiftLogLogger(subsystem: "s").redactsPrivateValues == false)
        #expect(SwiftLogLogger(subsystem: "s", redactsPrivateValues: true).redactsPrivateValues)
    }

    @Test("SwiftLogLogger is constructible and callable on every target, Apple included")
    func swiftLogWorksEverywhere() {
        let logger = SwiftLogLogger(subsystem: "io.shikki.tests")
        for level in LogLevel.allCases {
            logger.log(level, category: .app, message: "portable", privacy: .public)
        }
        #expect(Bool(true), "the point is that this compiles and runs off AND on Apple")
    }
}
