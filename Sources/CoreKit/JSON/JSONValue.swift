import Foundation

// MARK: - JSONValue

/// Minimal `Sendable` JSON leaf value — the typed alternative to passing
/// `[String: Any]` across concurrency or API boundaries, where it defeats
/// `Sendable` and hides schema drift behind unchecked casts.
///
/// Extracted from shikki's `PlanRepository` (PR #1505 review: "this one is
/// supposed to be generic — extract it into our SPM"). CoreKit is the home
/// rather than NetKit because CoreKit already owns the JSON helper family
/// (`prettyJson`, `Dictionary.decode`, the PocketBase date strategy) and is
/// a dependency of NetKit, so both fleets see one definition.
///
/// Note: some third-party SDKs (e.g. SwiftMCPCore) ship their own
/// `JSONValue`; in files importing both, qualify as `CoreKit.JSONValue`.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    /// Best-effort conversion from an untyped JSON scalar/collection
    /// (a `JSONSerialization` product). Types this enum does not model
    /// become `.null`.
    public init(untyped: Any) {
        switch untyped {
        case let s as String: self = .string(s)
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .integer(Int64(i))
        case let i as Int64: self = .integer(i)
        case let d as Double: self = .double(d)
        case let n as NSNumber:
            // NSNumber straddles Bool/Int/Double — disambiguate on objCType.
            let type = String(cString: n.objCType)
            if type == "c" || type == "B" {
                self = .bool(n.boolValue)
            } else if type == "q" || type == "l" || type == "i" || type == "s" {
                self = .integer(n.int64Value)
            } else {
                self = .double(n.doubleValue)
            }
        case let arr as [Any]:
            self = .array(arr.map(JSONValue.init(untyped:)))
        case let dict as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, v) in dict { out[k] = JSONValue(untyped: v) }
            self = .object(out)
        case is NSNull: self = .null
        default: self = .null
        }
    }

    /// Reverse of ``init(untyped:)`` — hand a Foundation-compatible tree
    /// back to a caller that must speak `JSONSerialization`.
    public var untyped: Any {
        switch self {
        case let .string(s): return s
        case let .integer(i): return NSNumber(value: i)
        case let .double(d): return NSNumber(value: d)
        case let .bool(b): return NSNumber(value: b)
        case let .array(a): return a.map(\.untyped)
        case let .object(o):
            var out: [String: Any] = [:]
            for (k, v) in o { out[k] = v.untyped }
            return out
        case .null: return NSNull()
        }
    }
}
