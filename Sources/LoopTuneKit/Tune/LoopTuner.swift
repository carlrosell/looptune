import Foundation

/// The raw output of one tuning run, before guardrail clamping and presentation.
public struct TuningOutput: Sendable, Equatable {
    public var tunedBasalHourly: [Double]
    public var pumpBasalHourly: [Double]
    public var untunedBasalHours: [Bool]

    public var tunedISF: Double
    public var pumpISF: Double

    public var tunedCarbRatio: Double
    public var pumpCarbRatio: Double

    /// Count of categorized samples per category (for confidence reporting).
    public var categoryCounts: [DeviationCategory: Int]
    /// Total categorized samples analyzed.
    public var totalSamples: Int

    public init(
        tunedBasalHourly: [Double],
        pumpBasalHourly: [Double],
        untunedBasalHours: [Bool],
        tunedISF: Double,
        pumpISF: Double,
        tunedCarbRatio: Double,
        pumpCarbRatio: Double,
        categoryCounts: [DeviationCategory: Int],
        totalSamples: Int
    ) {
        self.tunedBasalHourly = tunedBasalHourly
        self.pumpBasalHourly = pumpBasalHourly
        self.untunedBasalHours = untunedBasalHours
        self.tunedISF = tunedISF
        self.pumpISF = pumpISF
        self.tunedCarbRatio = tunedCarbRatio
        self.pumpCarbRatio = pumpCarbRatio
        self.categoryCounts = categoryCounts
        self.totalSamples = totalSamples
    }
}

/// Orchestrates one tuning run: replay → categorize → tune basal/ISF/CR.
///
/// This performs a single pass over the supplied window. Multi-day chaining
/// (feeding each day's tuned profile into the next, with the pump profile fixed
/// as the cap baseline) is layered on top by `runDayChained` once daily windows
/// are produced.
public struct LoopTuner: Sendable {
    let caps: TuningCaps
    let options: CategorizerOptions

    public init(caps: TuningCaps = TuningCaps(), options: CategorizerOptions = CategorizerOptions()) {
        self.caps = caps
        self.options = options
    }

    /// Tune against a single window.
    ///
    /// - Parameters:
    ///   - currentProfile: the profile to adjust (equals `pumpProfile` on a
    ///     fresh run; the evolving profile when chaining days).
    ///   - pumpProfile: the fixed pump baseline used for all safety caps.
    public func tune(
        deviations: [DeviationSample],
        carbs: [CarbRecord],
        currentProfile: TherapyProfile,
        pumpProfile: TherapyProfile,
        analysisStart: Date,
        analysisEnd: Date
    ) -> TuningOutput {
        let categorizer = Categorizer(profile: currentProfile, options: options)
        let categorized = categorizer.categorize(deviations)

        let currentISF = currentProfile.sensitivitySchedule.timeWeightedAverage()
        let pumpISF = pumpProfile.sensitivitySchedule.timeWeightedAverage()
        let currentCR = currentProfile.carbRatioSchedule.timeWeightedAverage()
        let pumpCR = pumpProfile.carbRatioSchedule.timeWeightedAverage()

        // ISF first — CR tuning consumes the tuned ISF.
        let isfTuner = SensitivityTuner(caps: caps)
        let tunedISF = isfTuner.tune(samples: categorized, currentISF: currentISF, pumpISF: pumpISF)

        let basalTuner = BasalTuner(timeZone: currentProfile.timeZone, caps: caps)
        let basalResult = basalTuner.tune(
            samples: categorized,
            currentHourly: currentProfile.basalSchedule.hourlyValues(),
            pumpHourly: pumpProfile.basalSchedule.hourlyValues(),
            isf: currentISF
        )

        let totalMealCarbs = carbs
            .filter { $0.date >= analysisStart && $0.date <= analysisEnd }
            .reduce(0.0) { $0 + $1.grams }
        let crTuner = CarbRatioTuner(caps: caps)
        let tunedCR = crTuner.tune(
            samples: categorized,
            totalMealCarbs: totalMealCarbs,
            replayISF: currentISF,
            targetISF: tunedISF,
            currentCR: currentCR,
            pumpCR: pumpCR
        )

        var counts: [DeviationCategory: Int] = [:]
        for entry in categorized { counts[entry.category, default: 0] += 1 }

        return TuningOutput(
            tunedBasalHourly: basalResult.hourlyRates,
            pumpBasalHourly: pumpProfile.basalSchedule.hourlyValues(),
            untunedBasalHours: basalResult.untuned,
            tunedISF: tunedISF,
            pumpISF: pumpISF,
            tunedCarbRatio: tunedCR,
            pumpCarbRatio: pumpCR,
            categoryCounts: counts,
            totalSamples: categorized.count
        )
    }
}
