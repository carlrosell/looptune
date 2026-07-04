import Foundation

/// A single 5-minute analysis datum produced by replaying history through the
/// Loop algorithm. This is the Loop-native analogue of oref0's per-datum record
/// and the unit the tuner categorizes and sums over.
public struct DeviationSample: Sendable, Equatable {
    /// End of the interval this datum describes (the later CGM timestamp).
    public var date: Date
    /// Blood glucose (mg/dL) at `date`.
    public var glucose: Double
    /// Mean 5-minute glucose delta over the trailing ~20 minutes (oref0's
    /// `avgDelta`), mg/dL.
    public var averageDelta: Double
    /// Insulin-only modeled glucose change over this interval (oref0's `BGI`),
    /// mg/dL — negative when insulin is active.
    public var insulinEffect: Double
    /// Observed minus modeled (insulin + carb) glucose change over this interval
    /// (the "deviation"), mg/dL.
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
        carbsOnBoard: Double
    ) {
        self.date = date
        self.glucose = glucose
        self.averageDelta = averageDelta
        self.insulinEffect = insulinEffect
        self.deviation = deviation
        self.insulinOnBoard = insulinOnBoard
        self.carbsOnBoard = carbsOnBoard
    }
}
