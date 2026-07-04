import Foundation

// Nightscout documents are produced by many uploaders and are notoriously
// loosely typed: numbers arrive as JSON strings, booleans as `"true"`, and
// dates in several formats. These helpers decode defensively.

extension KeyedDecodingContainer {
    /// A `Double` encoded as either a JSON number or a numeric string.
    func lenientDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            return Double(string.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// An `Int` encoded as a number or numeric string.
    func lenientInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = lenientDouble(forKey: key) {
            return Int(value)
        }
        return nil
    }

    /// A `Bool` encoded as a bool, `"true"`/`"false"`, or `0`/`1`.
    func lenientBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        if let number = lenientInt(forKey: key) {
            return number != 0
        }
        return nil
    }

    /// A `String` (passes through actual strings; stringifies numbers).
    func lenientString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        return nil
    }
}

/// Parses the assorted timestamp formats Nightscout emits: ISO-8601 with or
/// without fractional seconds and with `Z` or numeric offsets, plus epoch
/// milliseconds (as number or string).
enum NightscoutDate {
    // ISO8601DateFormatter is documented thread-safe for parsing.
    nonisolated(unsafe) private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let withoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parse an ISO-8601 string in either fractional or whole-second form.
    static func parseISO(_ string: String) -> Date? {
        withFractional.date(from: string) ?? withoutFractional.date(from: string)
    }

    /// Parse epoch milliseconds into a `Date`.
    static func fromEpochMilliseconds(_ millis: Double) -> Date {
        Date(timeIntervalSince1970: millis / 1000)
    }
}
