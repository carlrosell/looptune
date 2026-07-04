import Foundation
import LoopAlgorithm

/// A repeating daily schedule keyed by local time of day — the shape Nightscout
/// and pumps use for basal rates, insulin sensitivity, carb ratio, and targets.
///
/// Each entry starts at its `secondsSinceMidnight` offset (local wall-clock time
/// in the profile's timezone) and remains active until the next entry; the last
/// entry runs to the end of the day. The first entry must start at midnight
/// (offset 0), matching Loop/Nightscout requirements.
///
/// Expansion to absolute timelines is DST-correct: boundaries are resolved as
/// wall-clock components in the target timezone, so a schedule change at 02:00
/// lands at 02:00 local on every calendar day regardless of daylight-saving
/// shifts.
public struct DailySchedule<Value: Sendable & Equatable>: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// Seconds since local midnight, in `[0, 86400)`.
        public var secondsSinceMidnight: Int
        public var value: Value

        public init(secondsSinceMidnight: Int, value: Value) {
            self.secondsSinceMidnight = secondsSinceMidnight
            self.value = value
        }
    }

    /// Entries sorted ascending by offset; guaranteed non-empty with a leading
    /// midnight entry after initialization.
    public let entries: [Entry]

    public enum ScheduleError: Error, Equatable {
        case empty
        case missingMidnightEntry(firstOffset: Int)
        case offsetOutOfRange(Int)
    }

    /// Create a schedule, validating and normalizing the entries.
    ///
    /// - Duplicate offsets keep the **last** value (Nightscout profiles sometimes
    ///   carry duplicate `timeAsSeconds` entries; AutotuneWeb resolves them the
    ///   same way).
    /// - Adjacent entries with equal values are collapsed.
    /// - Requires a leading entry at offset 0.
    public init(entries rawEntries: [Entry]) throws {
        guard !rawEntries.isEmpty else { throw ScheduleError.empty }
        for entry in rawEntries where !(0..<86_400).contains(entry.secondsSinceMidnight) {
            throw ScheduleError.offsetOutOfRange(entry.secondsSinceMidnight)
        }

        // Sort, then dedupe by offset keeping the last occurrence.
        let sorted = rawEntries.sorted { $0.secondsSinceMidnight < $1.secondsSinceMidnight }
        var byOffset: [Int: Value] = [:]
        var order: [Int] = []
        for entry in sorted {
            if byOffset[entry.secondsSinceMidnight] == nil {
                order.append(entry.secondsSinceMidnight)
            }
            byOffset[entry.secondsSinceMidnight] = entry.value
        }

        var deduped = order.map { Entry(secondsSinceMidnight: $0, value: byOffset[$0]!) }

        guard let first = deduped.first, first.secondsSinceMidnight == 0 else {
            throw ScheduleError.missingMidnightEntry(firstOffset: deduped.first?.secondsSinceMidnight ?? -1)
        }

        // Collapse adjacent equal-valued blocks.
        var collapsed: [Entry] = []
        for entry in deduped {
            if let last = collapsed.last, last.value == entry.value { continue }
            collapsed.append(entry)
        }
        deduped = collapsed

        self.entries = deduped
    }

    /// The scheduled value active at the given number of seconds since local
    /// midnight (the last entry whose offset is `<=` the query).
    public func value(atSecondsSinceMidnight seconds: Int) -> Value {
        var result = entries[0].value
        for entry in entries where entry.secondsSinceMidnight <= seconds {
            result = entry.value
        }
        return result
    }

    /// The scheduled value active at an absolute instant, evaluated in `timeZone`.
    public func value(at date: Date, timeZone: TimeZone) -> Value {
        value(atSecondsSinceMidnight: Self.secondsSinceMidnight(of: date, in: timeZone))
    }

    /// Expand into an absolute, contiguous timeline that exactly tiles
    /// `[start, end]`, suitable for LoopAlgorithm inputs. Adjacent equal-valued
    /// segments are merged.
    public func expand(from start: Date, to end: Date, timeZone: TimeZone) -> [AbsoluteScheduleValue<Value>] {
        precondition(start <= end, "start must be <= end")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Collect boundary instants for each entry across every day that could
        // influence [start, end]. Include the prior day so the segment covering
        // `start` has a defined active value.
        let startDay = calendar.startOfDay(for: start)
        var day = calendar.date(byAdding: .day, value: -1, to: startDay) ?? startDay
        var boundaries: [Date] = []
        while day <= end {
            let dayComponents = calendar.dateComponents([.year, .month, .day], from: day)
            for entry in entries {
                var components = dayComponents
                components.hour = entry.secondsSinceMidnight / 3600
                components.minute = (entry.secondsSinceMidnight % 3600) / 60
                components.second = entry.secondsSinceMidnight % 60
                if let boundary = calendar.date(from: components) {
                    boundaries.append(boundary)
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        boundaries.sort()

        // Clip to (start, end) and frame with the window bounds.
        var cutPoints: [Date] = [start]
        for boundary in boundaries where boundary > start && boundary < end {
            if boundary != cutPoints.last {
                cutPoints.append(boundary)
            }
        }
        cutPoints.append(end)

        var result: [AbsoluteScheduleValue<Value>] = []
        for index in 0..<(cutPoints.count - 1) {
            let segmentStart = cutPoints[index]
            let segmentEnd = cutPoints[index + 1]
            guard segmentStart < segmentEnd else { continue }
            let value = self.value(at: segmentStart, timeZone: timeZone)
            if var last = result.last, last.value == value {
                last.endDate = segmentEnd
                result[result.count - 1] = last
            } else {
                result.append(AbsoluteScheduleValue(startDate: segmentStart, endDate: segmentEnd, value: value))
            }
        }
        return result
    }

    static func secondsSinceMidnight(of date: Date, in timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60 + (components.second ?? 0)
    }
}

public extension DailySchedule where Value == Double {
    /// The schedule sampled at each hour boundary (index 0…23), used by the
    /// per-hour basal tuner.
    func hourlyValues() -> [Double] {
        (0..<24).map { value(atSecondsSinceMidnight: $0 * 3600) }
    }

    /// The duration-weighted average value across the 24-hour day — a
    /// representative single value when a schedule has multiple entries (the
    /// approach nighttune uses to reduce ISF/CR schedules to one number).
    func timeWeightedAverage() -> Double {
        var total = 0.0
        for index in entries.indices {
            let start = entries[index].secondsSinceMidnight
            let end = index + 1 < entries.count ? entries[index + 1].secondsSinceMidnight : 86_400
            total += entries[index].value * Double(end - start)
        }
        return total / 86_400
    }
}

public extension DailySchedule.Entry {
    /// Convenience initializer from an `HH:mm` or `HH:mm:ss` string.
    init?(time: String, value: Value) {
        let parts = time.split(separator: ":").map { Int($0) }
        guard parts.count >= 2, let hour = parts[0], let minute = parts[1] else { return nil }
        let second = parts.count >= 3 ? (parts[2] ?? 0) : 0
        guard (0..<24).contains(hour), (0..<60).contains(minute), (0..<60).contains(second) else { return nil }
        self.init(secondsSinceMidnight: hour * 3600 + minute * 60 + second, value: value)
    }
}
