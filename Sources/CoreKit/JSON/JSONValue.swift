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
    ///
    /// A number is classified by what it IS, never by what it can be cast to:
    /// Foundation bridges every `NSNumber` to `Bool` (and `0`/`1` succeed), so
    /// asking `as Bool` first turns the JSON integers `0` and `1` into
    /// booleans. A bridged `NSNumber` is told apart by its `objCType`
    /// (`c`/`B` is a boolean — `JSONSerialization` produces nothing else with
    /// that type on Darwin and on Linux, both measured), and a native Swift
    /// value by its exact dynamic type.
    public init(untyped: Any) {
        switch untyped {
        case let s as String: self = .string(s)
        case let arr as [Any]: self = .array(arr.map(JSONValue.init(untyped:)))
        case let dict as [String: Any]: self = .object(dict.mapValues(JSONValue.init(untyped:)))
        case is NSNull: self = .null
        default: self = Self.scalar(untyped)
        }
    }

    private static func scalar(_ value: Any) -> JSONValue {
        // Native Swift values first, by exact type: `Bool` and `Int` both bridge
        // to `NSNumber`, and an `Int8` bridges to a type the NSNumber branch
        // below would read as a boolean.
        let dynamicType = type(of: value)
        if dynamicType == Bool.self, let bool = value as? Bool { return .bool(bool) }
        if let integer = value as? any FixedWidthInteger { return fromInteger(integer) }
        if dynamicType == Double.self, let double = value as? Double { return .double(double) }
        guard let number = value as? NSNumber else { return .null }
        return fromNumber(number)
    }

    /// A native integer of any width: an integer while it fits `Int64`, else a double.
    private static func fromInteger<Integer: FixedWidthInteger>(_ value: Integer) -> JSONValue {
        if let fits = Int64(exactly: value) { return .integer(fits) }
        return .double(Double(value))
    }

    private static func fromNumber(_ number: NSNumber) -> JSONValue {
        switch String(cString: number.objCType) {
        case "c", "B":
            .bool(number.boolValue)
        case "q", "l", "i", "s", "C", "S", "I", "L":
            .integer(number.int64Value)
        case "Q":
            // Unsigned 64-bit: an integer only while it fits, else a double.
            fromInteger(number.uint64Value)
        default:
            .double(number.doubleValue)
        }
    }

    /// Reverse of ``init(untyped:)`` — hand a Foundation-compatible tree
    /// back to a caller that must speak `JSONSerialization`.
    public var untyped: Any {
        switch self {
        case .string(let s): return s
        case .integer(let i): return NSNumber(value: i)
        case .double(let d): return NSNumber(value: d)
        case .bool(let b): return NSNumber(value: b)
        case .array(let a): return a.map(\.untyped)
        case .object(let o):
            var out: [String: Any] = [:]
            for (k, v) in o { out[k] = v.untyped }
            return out
        case .null: return NSNull()
        }
    }
}
