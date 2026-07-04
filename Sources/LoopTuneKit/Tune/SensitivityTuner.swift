import Foundation

/// Tunes a single ISF value from ISF-categorized deviations, following oref0's
/// median-ratio method.
public struct SensitivityTuner: Sendable {
    let caps: TuningCaps

    public init(caps: TuningCaps = TuningCaps()) {
        self.caps = caps
    }

    /// Minimum number of ISF-categorized data points required to move ISF.
    public static let minimumDataPoints = 10

    /// - Parameters:
    ///   - samples: categorized deviations (only `.isf` are used).
    ///   - currentISF: current (possibly already-tuned) ISF, mg/dL/U.
    ///   - pumpISF: fixed pump ISF baseline, mg/dL/U.
    public func tune(samples: [CategorizedSample], currentISF: Double, pumpISF: Double) -> Double {
        let isfSamples = samples.filter { $0.category == .isf }
        guard isfSamples.count >= Self.minimumDataPoints else { return currentISF }

        // Per-datum autosens-style ratio: 1 + deviation/BGI (BGI is negative when
        // insulin is active; positive deviations pull the ratio below 1).
        var ratios: [Double] = []
        for entry in isfSamples {
            let bgi = entry.sample.insulinEffect
            guard bgi != 0 else { continue }
            ratios.append(1 + entry.sample.deviation / bgi)
        }
        guard !ratios.isEmpty else { return currentISF }

        let medianRatio = TuningMath.median(ratios)
        let fullNewISF = currentISF * medianRatio
        guard fullNewISF > 0 else { return currentISF }

        // Optional blend toward pump ISF.
        let adjustedISF = caps.isfAdjustmentFraction * fullNewISF + (1 - caps.isfAdjustmentFraction) * pumpISF

        // ISF caps are inverted vs basal/CR (a lower autosens ratio → higher ISF).
        let minISF = pumpISF / caps.autotuneMax
        let maxISF = pumpISF / caps.autotuneMin
        let cappedAdjusted = TuningMath.clamp(adjustedISF, minISF, maxISF)

        // Move 20% toward the adjusted value, then re-cap.
        let newISF = (1 - caps.stepFraction) * currentISF + caps.stepFraction * cappedAdjusted
        return (TuningMath.clamp(newISF, minISF, maxISF) * 1000).rounded() / 1000
    }
}
