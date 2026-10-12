import Foundation

/// Per-run safety multipliers applied relative to the fixed pump profile, so
/// multi-day drift stays bounded (oref0 defaults).
public struct TuningCaps: Sendable, Equatable {
    /// Upper multiplier vs pump value (basal/CR); default 1.2.
    public var autotuneMax: Double
    /// Lower multiplier vs pump value (basal/CR); default 0.7.
    public var autotuneMin: Double
    /// Fraction of the fully-computed change applied per run (default 0.2 = 20%).
    public var stepFraction: Double
    /// Blend toward pump ISF (1.0 = no blend), oref0's `autotune_isf_adjustmentFraction`.
    public var isfAdjustmentFraction: Double

    public init(
        autotuneMax: Double = 1.2,
        autotuneMin: Double = 0.7,
        stepFraction: Double = 0.2,
        isfAdjustmentFraction: Double = 1.0
    ) {
        self.autotuneMax = autotuneMax
        self.autotuneMin = autotuneMin
        self.stepFraction = stepFraction
        self.isfAdjustmentFraction = isfAdjustmentFraction
    }
}

enum TuningMath {
    /// Linear-interpolated percentile of a sorted array, reproducing oref0's
    /// `lib/percentile.js` **exactly**: `index = n * p`, interpolating between
    /// adjacent ranks.
    ///
    /// This is intentionally oref0's formula, not the textbook
    /// `index = (n − 1) · p`. Autotune uses this to take the median of ISF
    /// ratios, and LoopTune's goal is to faithfully reproduce autotune's tuning
    /// behavior. The two formulas differ by at most one rank; at the ≥10-sample
    /// minimum the tuner enforces (typically 50–200 ISF points), the difference
    /// is well under 1%. The parity tests pin oref0's values deliberately.
    static func percentile(_ sortedValues: [Double], _ p: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        if sortedValues.count == 1 { return sortedValues[0] }
        let n = Double(sortedValues.count)
        let rank = n * p
        let lowerIndex = max(0, min(sortedValues.count - 1, Int(rank.rounded(.down))))
        let upperIndex = min(sortedValues.count - 1, lowerIndex + 1)
        let fraction = rank - Double(lowerIndex)
        return sortedValues[lowerIndex] + (sortedValues[upperIndex] - sortedValues[lowerIndex]) * fraction
    }

    static func median(_ values: [Double]) -> Double {
        percentile(values.sorted(), 0.5)
    }

    /// `percentile` generalized to weighted values: each value occupies a span
    /// of rank equal to its weight instead of one. With every weight equal to
    /// one this is exactly `percentile`, so oref0 parity is unchanged.
    static func weightedPercentile(_ values: [(value: Double, weight: Double)], _ p: Double) -> Double {
        let sorted = values
            .filter { $0.weight > 0 }
            .sorted { ($0.value, $0.weight) < ($1.value, $1.weight) }
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0].value }
        let rank = sorted.reduce(0) { $0 + $1.weight } * p
        var lowerIndex = 0
        var lowerStart = 0.0
        var start = 0.0
        for index in sorted.indices {
            guard start <= rank else { break }
            lowerIndex = index
            lowerStart = start
            start += sorted[index].weight
        }
        let upperIndex = min(sorted.count - 1, lowerIndex + 1)
        let fraction = (rank - lowerStart) / sorted[lowerIndex].weight
        let lower = sorted[lowerIndex].value
        return lower + (sorted[upperIndex].value - lower) * fraction
    }

    static func weightedMedian(_ values: [(value: Double, weight: Double)]) -> Double {
        weightedPercentile(values, 0.5)
    }

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
