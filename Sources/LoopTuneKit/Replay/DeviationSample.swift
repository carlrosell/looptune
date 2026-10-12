import Foundation

/// One CGM interval produced by replaying history through the Loop algorithm.
/// This is the Loop-native analogue of oref0's per-datum record and the unit
/// the tuner categorizes.
///
/// Glucose changes are expressed per five minutes, so per-datum thresholds do
/// not depend on CGM cadence. Aggregates weight each datum by `duration`, and
/// evidence is counted in five-minute intervals, so a trajectory carries the
/// same weight whether it was sampled every minute or every fifteen.
public struct DeviationSample: Sendable, Equatable {
    /// The duration oref0 thresholds and parity fixtures assume for one datum.
    public static let standardDuration: TimeInterval = 5 * 60

    /// End of the interval this datum describes (the later CGM timestamp).
    public var date: Date
    /// Seconds between the CGM readings that bound this interval.
    public var duration: TimeInterval
    /// Blood glucose (mg/dL) at `date`.
    public var glucose: Double
    /// Mean 5-minute glucose delta over the trailing ~20 minutes (oref0's
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

    /// Whole five-minute intervals in `duration` seconds of evidence, rounded
    /// to the nearest interval so timestamp jitter does not lose one.
    public static func fiveMinuteIntervals(in duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        return Int((duration / standardDuration).rounded())
    }

    /// Total evidence, in five-minute intervals, carried by `samples`.
    public static func fiveMinuteIntervals(of samples: [DeviationSample]) -> Int {
        fiveMinuteIntervals(in: samples.reduce(0) { $0 + $1.duration })
    }
}
