import CoreKitTestSupport
import Foundation
import Testing

extension TestScratch {
    /// Cleanup for `defer` and teardown closures: a failed or incomplete sweep is recorded as an issue on the
    /// running test, so a scratch leak FAILS it instead of passing silently as `try?` did.
    /// `Issue.record` binds to the current test through Swift Testing's task-local context, not a global.
    func sweep(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) {
        sweep(url) { Issue.record(Comment(rawValue: $0), sourceLocation: sourceLocation) }
    }
}
