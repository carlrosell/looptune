import Foundation

/// Whether a basal hour or schedule block has evidence of its own behind its
/// recommended value (ADR 0011).
public enum BlockEvidenceStatus: String, Sendable, Equatable, Codable {
    /// Usable evidence under the final settings supports the recommended value.
    case tuned
    /// The block's own evidence was insufficient. Its recommended value is the
    /// pump value, and an interpolated alternative may be offered beside it.
    case insufficientData
    /// A run saved before ADR 0011: the block had no usable evidence, and its
    /// recommended value is whatever that version carried forward.
    case carriedForward
}

/// The values offered for a block without sufficient evidence of its own
/// under the final settings (ADR 0011). LoopTune does not choose between them:
/// the block's recommended value stays the pump value, and the interpolated
/// alternative is shown beside it so the user can decide which to enter.
public struct InsufficientEvidence<Alternative: Sendable & Equatable>: Sendable, Equatable {
    /// The value interpolated from evidence-backed blocks, inside this block's
    /// limits. `nil` when no other block in the schedule had evidence.
    public var interpolated: Alternative?
    /// Start offsets, in seconds since local midnight, of the evidence-backed
    /// blocks `interpolated` came from: the nearest before and after, or the
    /// single block with evidence. Empty when `interpolated` is `nil`.
    public var sources: [Int]

    public init(interpolated: Alternative?, sources: [Int]) {
        self.interpolated = interpolated
        self.sources = interpolated == nil ? [] : sources
    }

    /// Source start times as `HH:mm`.
    public var sourceTimes: [String] { sources.map(Self.timeString) }

    /// Why this block has no recommendation of its own and where the
    /// alternative came from.
    public var note: String {
        let times = sourceTimes
        switch times.count {
        case 0:
            return "Not enough data of its own, and no block had enough data to interpolate from. Only the pump value is shown."
        case 1:
            return "Not enough data of its own. Interpolated from \(times[0]), the only block with enough data."
        default:
            return "Not enough data of its own. Interpolated from \(times.joined(separator: " and ")), the nearest blocks with enough data."
        }
    }

    static func timeString(_ secondsSinceMidnight: Int) -> String {
        let hour = secondsSinceMidnight / 3600
        let minute = secondsSinceMidnight % 3600 / 60
        let second = secondsSinceMidnight % 60
        return second == 0
            ? String(format: "%02d:%02d", hour, minute)
            : String(format: "%02d:%02d:%02d", hour, minute, second)
    }
}

/// Formats a pump value at the precision it was stored with. A block with
/// insufficient data offers the pump value as one of the user's choices, so it
/// must not be shown rounded (ADR 0011).
public enum PumpValueFormat {
    /// `value` with the fewest decimals in `decimals` that show it exactly,
    /// or with `fallback` decimals when none does.
    public static func string(_ value: Double, decimals: ClosedRange<Int>, fallback: Int) -> String {
        let places = decimals.first { places in
            let scaled = value * pow(10, Double(places))
            return abs(scaled - scaled.rounded()) < 1e-6
        } ?? fallback
        return String(format: "%.\(places)f", value)
    }
}

/// The interpolation rule for blocks without sufficient evidence (ADR 0011).
///
/// Blocks form a cycle over the day. For a block without evidence, take the
/// nearest evidence-backed block before it and after it, wrapping at
/// midnight, and weight each by the time distance between block midpoints to
/// the other: `(before × dAfter + after × dBefore) / (dBefore + dAfter)`. When
/// only one block in the schedule has evidence, the nearest block in both
/// directions is that block and its value is used. Without any other
/// evidence-backed block, including a single-block schedule, there is no
/// alternative.
enum ScheduleInterpolation {
    static let secondsPerDay = 86_400

    /// - Parameters:
    ///   - index: the block to interpolate.
    ///   - starts: every block's start offset, ascending from 0.
    ///   - values: each block's evidence-backed value, or `nil` without one.
    static func interpolate(
        at index: Int,
        starts: [Int],
        values: [Double?]
    ) -> (value: Double, sources: [Int])? {
        let count = starts.count
        guard count > 1, values.count == count, starts.indices.contains(index) else { return nil }
        let candidates = (1..<count).map { (index + $0) % count }
        guard let after = candidates.first(where: { values[$0] != nil }),
              let before = candidates.last(where: { values[$0] != nil }),
              let afterValue = values[after],
              let beforeValue = values[before] else {
            return nil
        }
        if before == after {
            return (afterValue, [starts[after]])
        }
        let midpoints = starts.indices.map { block in
            let end = block + 1 < count ? starts[block + 1] : secondsPerDay
            return Double(starts[block] + end) / 2
        }
        let day = Double(secondsPerDay)
        func forward(_ from: Double, _ to: Double) -> Double {
            let distance = (to - from).truncatingRemainder(dividingBy: day)
            return distance < 0 ? distance + day : distance
        }
        let distanceBefore = forward(midpoints[before], midpoints[index])
        let distanceAfter = forward(midpoints[index], midpoints[after])
        let value = (beforeValue * distanceAfter + afterValue * distanceBefore) / (distanceBefore + distanceAfter)
        return (value, [starts[before], starts[after]])
    }
}
