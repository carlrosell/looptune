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

    /// A present numeric field must decode to a finite value. Optional means
    /// absent/null is allowed—not that malformed or non-finite data is ignored.
    func finiteLenientDouble(forKey key: Key) throws -> Double? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else { return nil }
        guard let value = lenientDouble(forKey: key), value.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "numeric value is malformed or non-finite"
            )
        }
        return value
    }

    /// An `Int` encoded as a number or numeric string. Non-finite doubles are
    /// rejected (rather than trapping in `Int(_:)`).
    func lenientInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = lenientDouble(forKey: key),
           value.isFinite,
           value >= Double(Int.min),
           value < Double(Int.max) {
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

    /// A present boolean field may use Nightscout's common bool/string/number
    /// spellings, but any other representation is corruption rather than nil.
    func strictLenientBool(forKey key: Key) throws -> Bool? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else { return nil }
        guard let value = lenientBool(forKey: key) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "boolean value is malformed"
            )
        }
        return value
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
///
/// Parsed dates must lie in `epochMillisecondRange`; anything outside is
/// rejected, never clamped. Every date in range converts back to integer
/// epoch milliseconds and to a four-digit-year ISO string, so cached
/// documents re-encode without trapping.
enum NightscoutDate {
    /// 0001-01-01T00:00:00Z through 9999-12-31T23:59:59.999Z, in epoch
    /// milliseconds: the instants ISO-8601 writes with a four-digit year.
    /// Both bounds are exact in `Double` and far inside `Int64`.
    static let epochMillisecondRange: ClosedRange<Double> = -62_135_596_800_000 ... 253_402_300_799_999

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
        guard let date = withFractional.date(from: string) ?? withoutFractional.date(from: string),
              epochMilliseconds(date) != nil else { return nil }
        return date
    }

    /// Parse epoch milliseconds into a `Date`, or `nil` when the value is
    /// non-finite or outside `epochMillisecondRange`.
    static func fromEpochMilliseconds(_ millis: Double) -> Date? {
        // `contains` is false for NaN.
        guard epochMillisecondRange.contains(millis) else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    /// The date as whole epoch milliseconds, rounded to nearest, or `nil`
    /// when it falls outside `epochMillisecondRange`.
    static func epochMilliseconds(_ date: Date) -> Int64? {
        let millis = (date.timeIntervalSince1970 * 1000).rounded()
        guard epochMillisecondRange.contains(millis) else { return nil }
        return Int64(exactly: millis)
    }
}
