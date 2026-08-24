import Foundation

/// Tunes a single carb ratio from carb-absorption (CSF) deviations.
///
/// This adapts oref0's CSF logic to Loop-native deviations. In oref0 the
/// deviation during a meal *is* the carb impact. In LoopTune the replay already
/// subtracts the modeled carb effect, so a CSF-categorized deviation is the
/// carb-model *residual*. Working in carb-sensitivity space:
///
/// - the replay modeled carbs with `CSF_replay = replayISF / currentCR`,
/// - the summed residual per gram reveals the true value:
///   `CSF_true = CSF_replay + Σdeviation / Σcarbs`,
/// - and the new ratio expresses that against the (possibly retuned) ISF:
///   `CR = targetISF / CSF_true`.
///
/// A positive net residual (carbs raised BG more than modeled) lowers CR; a
/// negative residual raises it.
public struct CarbRatioTuner: Sendable {
    let caps: TuningCaps
    /// Loop guardrail bounds for CR (g/U): absolute 2…150.
    let absoluteMinCR: Double
    let absoluteMaxCR: Double

    public init(caps: TuningCaps = TuningCaps(), absoluteMinCR: Double = 2, absoluteMaxCR: Double = 150) {
        self.caps = caps
        self.absoluteMinCR = absoluteMinCR
        self.absoluteMaxCR = absoluteMaxCR
    }

    struct Result: Sendable, Equatable {
        var value: Double
        var untuned: Bool
    }

    /// - Parameters:
    ///   - samples: categorized deviations (only `.csf` are used).
    ///   - totalMealCarbs: total grams of carbs eaten in the analysis window.
    ///   - replayISF: the ISF the replay used to model the carb effect (the
    ///     pre-tuning ISF).
    ///   - targetISF: the tuned ISF the new CR is expressed against.
    ///   - currentCR / pumpCR: current and pump carb ratios (g/U).
    public func tune(
        samples: [CategorizedSample],
        totalMealCarbs: Double,
        replayISF: Double,
        targetISF: Double,
        currentCR: Double,
        pumpCR: Double
    ) -> Double {
        let mealDeviations = samples
            .filter { $0.category == .csf }
            .reduce(0.0) { $0 + $1.sample.deviation }

        return tuneWithEvidence(
            mealDeviations: mealDeviations,
            totalMealCarbs: totalMealCarbs,
            replayISF: replayISF,
            targetISF: targetISF,
            currentCR: currentCR,
            pumpCR: pumpCR
        ).value
    }

    func tuneWithEvidence(
        mealDeviations: Double,
        totalMealCarbs: Double,
        replayISF: Double,
        targetISF: Double,
        currentCR: Double,
        pumpCR: Double
    ) -> Result {

        guard totalMealCarbs.isFinite, totalMealCarbs > 0,
              replayISF.isFinite, replayISF > 0,
              targetISF.isFinite, targetISF > 0,
              currentCR.isFinite, currentCR > 0,
              pumpCR.isFinite, pumpCR > 0,
              mealDeviations.isFinite else {
            return Result(value: currentCR, untuned: true)
        }

        let csfReplay = replayISF / currentCR
        let csfTrue = csfReplay + mealDeviations / totalMealCarbs
        guard csfTrue.isFinite, csfTrue > 0 else {
            return Result(value: currentCR, untuned: true)
        }

        let fullNewCR = targetISF / csfTrue

        let minCR = max(absoluteMinCR, pumpCR * caps.autotuneMin)
        let maxCR = min(absoluteMaxCR, pumpCR * caps.autotuneMax)
        let cappedFull = TuningMath.clamp(fullNewCR, minCR, maxCR)

        let newCR = (1 - caps.stepFraction) * currentCR + caps.stepFraction * cappedFull
        let value = (TuningMath.clamp(newCR, minCR, maxCR) * 1000).rounded() / 1000
        return Result(value: value, untuned: false)
    }
}
