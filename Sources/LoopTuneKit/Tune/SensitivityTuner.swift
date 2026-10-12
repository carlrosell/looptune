import Foundation

/// Tunes a single ISF value from ISF-categorized deviations, following oref0's
/// median-ratio method.
public struct SensitivityTuner: Sendable {
    let caps: TuningCaps

    public init(caps: TuningCaps = TuningCaps()) {
        self.caps = caps
    }

    /// Minimum usable ISF-categorized evidence, in five-minute intervals,
    /// required to move ISF.
    public static let minimumDataPoints = 10
    /// `minimumDataPoints` as CGM time (50 minutes). The check compares this
    /// duration, not a rounded count.
    public static let minimumEvidenceDuration = Double(minimumDataPoints) * DeviationSample.standardDuration

    struct Result: Sendable, Equatable {
        var value: Double
        /// Usable evidence in five-minute intervals.
        var usableSampleCount: Int
        var untuned: Bool
    }

    /// - Parameters:
    ///   - samples: categorized deviations (only `.isf` are used).
    ///   - currentISF: current (possibly already-tuned) ISF, mg/dL/U.
    ///   - pumpISF: fixed pump ISF baseline, mg/dL/U.
    public func tune(samples: [CategorizedSample], currentISF: Double, pumpISF: Double) -> Double {
        tuneWithEvidence(samples: samples, currentISF: currentISF, pumpISF: pumpISF).value
    }

    func tuneWithEvidence(
        samples: [CategorizedSample],
        currentISF: Double,
        pumpISF: Double
    ) -> Result {
        guard pumpISF.isFinite, pumpISF > 0 else {
            // Without a usable pump baseline there is no relative limit to apply.
            return Result(value: currentISF, usableSampleCount: 0, untuned: true)
        }
        // ISF caps are inverted vs basal/CR (a lower autosens ratio → higher ISF).
        let minISF = pumpISF / caps.autotuneMax
        let maxISF = pumpISF / caps.autotuneMin

        // Without usable evidence the current value carries forward. It may come
        // from a historical profile outside the limits anchored to the pump, so
        // cap it like a tuned value. An unusable current value falls back to
        // the pump baseline.
        func untuned(usableSampleCount: Int) -> Result {
            let value = currentISF.isFinite && currentISF > 0
                ? TuningMath.clamp(currentISF, minISF, maxISF)
                : pumpISF
            return Result(value: value, usableSampleCount: usableSampleCount, untuned: true)
        }

        guard currentISF.isFinite, currentISF > 0 else {
            return untuned(usableSampleCount: 0)
        }
        let isfSamples = samples.filter { $0.category == .isf }

        // Per-datum autosens-style ratio: 1 + deviation/BGI (BGI is negative when
        // insulin is active; positive deviations pull the ratio below 1). Each
        // ratio is weighted by the duration its sample covers.
        var ratios: [(value: Double, weight: Double)] = []
        var usableDuration: TimeInterval = 0
        for entry in isfSamples {
            let bgi = entry.sample.insulinEffect
            guard bgi.isFinite, bgi != 0, entry.sample.deviation.isFinite else { continue }
            let ratio = 1 + entry.sample.deviation / bgi
            if ratio.isFinite {
                ratios.append((ratio, entry.sample.weight))
                usableDuration += entry.sample.duration
            }
        }
        // The minimum applies to the duration of usable ratios, not merely
        // samples carrying the `.isf` label or their count. Otherwise one valid
        // datum plus nine zero/invalid BGIs, or ten minutes of one-minute CGM,
        // can move a medical setting.
        guard usableDuration >= Self.minimumEvidenceDuration else {
            return untuned(usableSampleCount: DeviationSample.completeFiveMinuteIntervals(in: usableDuration))
        }
        let usableIntervals = DeviationSample.fiveMinuteIntervals(in: usableDuration)

        // oref0 rounds p50ratios to 3 dp before multiplying (autotune/index.js).
        let medianRatio = (TuningMath.weightedMedian(ratios) * 1000).rounded() / 1000
        let fullNewISF = currentISF * medianRatio
        guard fullNewISF.isFinite, fullNewISF > 0 else {
            return untuned(usableSampleCount: usableIntervals)
        }

        // Optional blend toward pump ISF.
        let adjustedISF = caps.isfAdjustmentFraction * fullNewISF + (1 - caps.isfAdjustmentFraction) * pumpISF
        let cappedAdjusted = TuningMath.clamp(adjustedISF, minISF, maxISF)

        // Move 20% toward the adjusted value, then re-cap.
        let newISF = (1 - caps.stepFraction) * currentISF + caps.stepFraction * cappedAdjusted
        let value = (TuningMath.clamp(newISF, minISF, maxISF) * 1000).rounded() / 1000
        return Result(value: value, usableSampleCount: usableIntervals, untuned: false)
    }
}
