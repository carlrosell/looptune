import Foundation

/// One CGM interval produced by replaying history through the Loop algorithm.
/// This is the Loop-native analogue of oref0's per-datum record and the unit
/// the tuner categorizes.
///
/// Glucose changes are expressed per five minutes, so per-datum thresholds do
/// not depend on CGM cadence. Aggregates weight each datum by `duration`, and
/// evidence minimums compare that duration directly, so a trajectory carries
/// the same weight whether it was sampled every minute or every fifteen.
/// Evidence counts are reported in five-minute intervals.
public struct DeviationSample: Sendable, Equatable {
    /// The duration oref0 thresholds and parity fixtures assume for one datum.
    public static let standardDuration: TimeInterval = 5 * 60

    /// End of the interval this datum describes (the later CGM timestamp).
    public var date: Date
    /// Seconds between the CGM readings that bound this interval. Always
    /// finite and positive.
    public private(set) var duration: TimeInterval
    /// Blood glucose (mg/dL) at `date`.
    public var glucose: Double
    /// Mean 5-minute glucose delta over the trailing 20 minutes (oref0's
    /// `avgDelta`), mg/dL.
    public var averageDelta: Double
    /// Insulin-only modeled glucose change over this interval (oref0's `BGI`),
    /// mg/dL per five minutes — negative when insulin is active.
    public var insulinEffect: Double
    /// Observed minus modeled (insulin + carb) glucose change over this interval
    /// (the "deviation"), mg/dL per five minutes.
    public var deviation: Double
    /// Insulin on board at `date`, U.
    public var insulinOnBoard: Double
    /// Carbs on board at `date`, g (Loop's dynamic absorption).
    public var carbsOnBoard: Double

    /// - Precondition: `duration` is finite and positive. A zero, negative or
    ///   non-finite duration would silently distort every weighted sum.
    public init(
        date: Date,
        glucose: Double,
        averageDelta: Double,
        insulinEffect: Double,
        deviation: Double,
        insulinOnBoard: Double,
        carbsOnBoard: Double,
        duration: TimeInterval = DeviationSample.standardDuration
    ) {
        precondition(duration.isFinite && duration > 0, "DeviationSample duration must be finite and positive")
        self.date = date
        self.duration = duration
        self.glucose = glucose
        self.averageDelta = averageDelta
        self.insulinEffect = insulinEffect
        self.deviation = deviation
        self.insulinOnBoard = insulinOnBoard
        self.carbsOnBoard = carbsOnBoard
    }

    /// This datum's share of a sum, in five-minute intervals.
    public var weight: Double {
        duration / Self.standardDuration
    }

    /// Seconds of CGM time covered by `samples`. Evidence minimums compare
    /// this duration, not a rounded count.
    public static func totalDuration(of samples: [DeviationSample]) -> TimeInterval {
        samples.reduce(0) { $0 + $1.duration }
    }

    /// `duration` seconds of evidence as a reported count of five-minute
    /// intervals: the nearest whole interval, so timestamp jitter does not lose
    /// one, and at least one for any evidence, so a count of zero always
    /// means none.
    public static func fiveMinuteIntervals(in duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        return max(1, Int((duration / standardDuration).rounded()))
    }

    /// Total evidence carried by `samples`, as a reported count of five-minute
    /// intervals.
    public static func fiveMinuteIntervals(of samples: [DeviationSample]) -> Int {
        fiveMinuteIntervals(in: totalDuration(of: samples))
    }

    /// Five-minute intervals completed in `duration` seconds, rounded down.
    /// Reports a shortfall: evidence below a minimum never displays as meeting
    /// it.
    public static func completeFiveMinuteIntervals(in duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        return Int((duration / standardDuration).rounded(.down))
    }

    /// Reported five-minute interval counts for several evidence durations,
    /// apportioned by largest remainder so they add up to the reported count
    /// of the combined duration. Ties go to the earlier duration.
    static func fiveMinuteIntervals(apportioning durations: [TimeInterval]) -> [Int] {
        let usable = durations.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        var counts = usable.map { Int(($0 / standardDuration).rounded(.down)) }
        let remaining = fiveMinuteIntervals(in: usable.reduce(0, +)) - counts.reduce(0, +)
        let byRemainder = usable.indices
            .filter { usable[$0] > 0 }
            .map { (index: $0, remainder: usable[$0] / standardDuration - Double(counts[$0])) }
            .sorted { $0.remainder != $1.remainder ? $0.remainder > $1.remainder : $0.index < $1.index }
        for entry in byRemainder.prefix(max(0, remaining)) {
            counts[entry.index] += 1
        }
        return counts
    }
}
