import Foundation

/// One time block in a tuned ISF or carb-ratio schedule.
public struct ScheduleTuningOutput: Sendable, Equatable {
    public var secondsSinceMidnight: Int
    public var tunedValue: Double
    public var pumpValue: Double
    /// True when this block had too little usable evidence and stayed unchanged.
    public var untuned: Bool
    /// Usable ISF samples or logged meals behind this block.
    public var evidenceCount: Int
    /// Chained day windows in which this block had no usable tuning evidence.
    public var daysMissing: Int

    public init(
        secondsSinceMidnight: Int,
        tunedValue: Double,
        pumpValue: Double,
        untuned: Bool,
        evidenceCount: Int = 0,
        daysMissing: Int = 0
    ) {
        self.secondsSinceMidnight = secondsSinceMidnight
        self.tunedValue = tunedValue
        self.pumpValue = pumpValue
        self.untuned = untuned
        self.evidenceCount = evidenceCount
        self.daysMissing = daysMissing
    }
}

/// The raw output of one tuning run, before guardrail clamping and presentation.
public struct TuningOutput: Sendable, Equatable {
    public var tunedBasalHourly: [Double]
    public var pumpBasalHourly: [Double]
    public var untunedBasalHours: [Bool]

    public var sensitivitySchedule: [ScheduleTuningOutput]
    public var carbRatioSchedule: [ScheduleTuningOutput]

    /// Duration-weighted daily averages retained for summaries and source
    /// compatibility with the original single-value tuner.
    public var tunedISF: Double { Self.timeWeightedAverage(sensitivitySchedule, keyPath: \.tunedValue) }
    public var pumpISF: Double { Self.timeWeightedAverage(sensitivitySchedule, keyPath: \.pumpValue) }
    public var tunedCarbRatio: Double { Self.timeWeightedAverage(carbRatioSchedule, keyPath: \.tunedValue) }
    public var pumpCarbRatio: Double { Self.timeWeightedAverage(carbRatioSchedule, keyPath: \.pumpValue) }

    /// Count of categorized samples per category (for confidence reporting).
    public var categoryCounts: [DeviationCategory: Int]
    /// Total categorized samples analyzed.
    public var totalSamples: Int
    /// Basal-categorized samples per local hour (data coverage, for charts).
    public var basalSampleCountByHour: [Int]

    public init(
        tunedBasalHourly: [Double],
        pumpBasalHourly: [Double],
        untunedBasalHours: [Bool],
        tunedISF: Double,
        pumpISF: Double,
        tunedCarbRatio: Double,
        pumpCarbRatio: Double,
        categoryCounts: [DeviationCategory: Int],
        totalSamples: Int,
        basalSampleCountByHour: [Int] = Array(repeating: 0, count: 24)
    ) {
        self.tunedBasalHourly = tunedBasalHourly
        self.pumpBasalHourly = pumpBasalHourly
        self.untunedBasalHours = untunedBasalHours
        self.sensitivitySchedule = [ScheduleTuningOutput(
            secondsSinceMidnight: 0,
            tunedValue: tunedISF,
            pumpValue: pumpISF,
            untuned: false
        )]
        self.carbRatioSchedule = [ScheduleTuningOutput(
            secondsSinceMidnight: 0,
            tunedValue: tunedCarbRatio,
            pumpValue: pumpCarbRatio,
            untuned: false
        )]
        self.categoryCounts = categoryCounts
        self.totalSamples = totalSamples
        self.basalSampleCountByHour = basalSampleCountByHour
    }

    public init(
        tunedBasalHourly: [Double],
        pumpBasalHourly: [Double],
        untunedBasalHours: [Bool],
        sensitivitySchedule: [ScheduleTuningOutput],
        carbRatioSchedule: [ScheduleTuningOutput],
        categoryCounts: [DeviationCategory: Int],
        totalSamples: Int,
        basalSampleCountByHour: [Int] = Array(repeating: 0, count: 24)
    ) {
        precondition(sensitivitySchedule.first?.secondsSinceMidnight == 0)
        precondition(carbRatioSchedule.first?.secondsSinceMidnight == 0)
        self.tunedBasalHourly = tunedBasalHourly
        self.pumpBasalHourly = pumpBasalHourly
        self.untunedBasalHours = untunedBasalHours
        self.sensitivitySchedule = sensitivitySchedule
        self.carbRatioSchedule = carbRatioSchedule
        self.categoryCounts = categoryCounts
        self.totalSamples = totalSamples
        self.basalSampleCountByHour = basalSampleCountByHour
    }

    public func tunedSensitivityDailySchedule() throws -> DailySchedule<Double> {
        try DailySchedule(entries: sensitivitySchedule.map {
            .init(secondsSinceMidnight: $0.secondsSinceMidnight, value: $0.tunedValue)
        })
    }

    public func tunedCarbRatioDailySchedule() throws -> DailySchedule<Double> {
        try DailySchedule(entries: carbRatioSchedule.map {
            .init(secondsSinceMidnight: $0.secondsSinceMidnight, value: $0.tunedValue)
        })
    }

    private static func timeWeightedAverage(
        _ schedule: [ScheduleTuningOutput],
        keyPath: KeyPath<ScheduleTuningOutput, Double>
    ) -> Double {
        guard !schedule.isEmpty else { return 0 }
        var total = 0.0
        for index in schedule.indices {
            let start = schedule[index].secondsSinceMidnight
            let end = index + 1 < schedule.count ? schedule[index + 1].secondsSinceMidnight : 86_400
            total += schedule[index][keyPath: keyPath] * Double(end - start)
        }
        return total / 86_400
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

        // ISF first. Each pump-configured time block is tuned independently,
        // and CR tuning consumes that tuned schedule.
        let isfTuner = SensitivityTuner(caps: caps)
        let sensitivitySchedule = isfTuner.tuneSchedule(
            samples: categorized,
            currentSchedule: currentProfile.sensitivitySchedule,
            pumpSchedule: pumpProfile.sensitivitySchedule,
            timeZone: currentProfile.timeZone
        )

        let basalTuner = BasalTuner(timeZone: currentProfile.timeZone, caps: caps)
        let basalResult = basalTuner.tune(
            samples: categorized,
            currentHourly: currentProfile.basalSchedule.hourlyValues(),
            pumpHourly: pumpProfile.basalSchedule.hourlyValues(),
            isf: currentISF
        )

        let mealCarbs = carbs.filter { $0.date >= analysisStart && $0.date <= analysisEnd }
        let crTuner = CarbRatioTuner(caps: caps)
        let carbRatioSchedule = crTuner.tuneSchedule(
            samples: categorized,
            carbs: mealCarbs,
            currentProfile: currentProfile,
            pumpSchedule: pumpProfile.carbRatioSchedule,
            tunedSensitivity: sensitivitySchedule
        )

        var counts: [DeviationCategory: Int] = [:]
        for entry in categorized { counts[entry.category, default: 0] += 1 }

        return TuningOutput(
            tunedBasalHourly: basalResult.hourlyRates,
            pumpBasalHourly: pumpProfile.basalSchedule.hourlyValues(),
            untunedBasalHours: basalResult.untuned,
            sensitivitySchedule: sensitivitySchedule,
            carbRatioSchedule: carbRatioSchedule,
            categoryCounts: counts,
            totalSamples: categorized.count,
            basalSampleCountByHour: basalResult.sampleCounts
        )
    }
}
