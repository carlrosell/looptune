import Foundation

/// How large a recommended change is, using AutotuneWeb's highlight thresholds.
public enum ChangeTier: String, Sendable, Equatable {
    /// < 10% change.
    case minimal
    /// ≥ 10% change (worth attention).
    case notable
    /// ≥ +20% or ≤ −30% change (autotune's own caps — review carefully).
    case large

    public static func classify(pump: Double, tuned: Double) -> ChangeTier {
        guard pump != 0 else { return tuned == 0 ? .minimal : .large }
        let change = (tuned - pump) / pump
        if change >= 0.20 || change <= -0.30 { return .large }
        if abs(change) >= 0.10 { return .notable }
        return .minimal
    }
}

/// A single tunable parameter's recommendation. Values are stored canonically
/// (ISF in mg/dL/U); glucose-denominated parameters are converted for display.
public struct ParameterRecommendation: Sendable, Equatable {
    public var name: String
    /// Canonical unit label (mg/dL/U for ISF, g/U for carb ratio).
    public var unit: String
    public var pumpValue: Double
    /// The tuned value after guardrail clamping.
    public var recommendedValue: Double
    /// The raw tuned value before guardrail clamping.
    public var rawTunedValue: Double
    public var changeTier: ChangeTier
    public var guardrailStatus: LoopGuardrails.Status
    /// Percent change from pump to recommended (signed, unit-invariant).
    public var percentChange: Double
    /// Whether the value's numerator is a glucose quantity (mg/dL) and therefore
    /// convertible to mmol/L for display.
    public var isGlucoseDenominated: Bool

    public init(name: String, unit: String, pumpValue: Double, rawTunedValue: Double, bounds: LoopGuardrails.Bounds, isGlucoseDenominated: Bool) {
        self.name = name
        self.unit = unit
        self.pumpValue = pumpValue
        self.rawTunedValue = rawTunedValue
        let clamped = LoopGuardrails.clamp(rawTunedValue, to: bounds)
        self.recommendedValue = clamped.value
        self.guardrailStatus = clamped.status
        self.changeTier = ChangeTier.classify(pump: pumpValue, tuned: clamped.value)
        self.percentChange = pumpValue == 0 ? 0 : (clamped.value - pumpValue) / pumpValue * 100
        self.isGlucoseDenominated = isGlucoseDenominated
    }

    // MARK: - Display

    private func convert(_ value: Double, to displayUnit: GlucoseUnit) -> Double {
        isGlucoseDenominated ? displayUnit.fromMilligramsPerDeciliter(value) : value
    }

    public func pumpValue(in displayUnit: GlucoseUnit) -> Double { convert(pumpValue, to: displayUnit) }
    public func recommendedValue(in displayUnit: GlucoseUnit) -> Double { convert(recommendedValue, to: displayUnit) }
    public func rawTunedValue(in displayUnit: GlucoseUnit) -> Double { convert(rawTunedValue, to: displayUnit) }

    /// The unit label to show for a given display unit (e.g. "mmol/L/U" for ISF).
    public func unitLabel(in displayUnit: GlucoseUnit) -> String {
        guard isGlucoseDenominated else { return unit }
        return displayUnit.sensitivityUnitLabel
    }

    /// Sensible decimal places for the display unit.
    public func decimals(in displayUnit: GlucoseUnit) -> Int {
        isGlucoseDenominated && displayUnit == .millimolesPerLiter ? 2 : 1
    }

    /// A formatted value string in the display unit.
    public func formatted(_ value: Double, in displayUnit: GlucoseUnit) -> String {
        String(format: "%.\(decimals(in: displayUnit))f", value)
    }
}

public extension GlucoseUnit {
    /// Short glucose label ("mg/dL" / "mmol/L").
    var shortLabel: String {
        switch self {
        case .milligramsPerDeciliter: return "mg/dL"
        case .millimolesPerLiter: return "mmol/L"
        }
    }

    /// Sensitivity (ISF) unit label ("mg/dL/U" / "mmol/L/U").
    var sensitivityUnitLabel: String { shortLabel + "/U" }
}

/// One tuned basal hour.
public struct BasalHourRecommendation: Sendable, Equatable, Identifiable {
    /// Stable identity for table presentation: the hour of day.
    public var id: Int { hour }
    public var hour: Int
    public var pumpRate: Double
    public var recommendedRate: Double
    public var changeTier: ChangeTier
    public var guardrailStatus: LoopGuardrails.Status
    public var untuned: Bool
    /// Day windows in which this hour received no tuning data (confidence:
    /// higher = less real data behind the recommendation for this hour).
    public var daysMissing: Int
    /// Basal-categorized samples that informed this scheduled basal hour across
    /// the window. A deviation observed at hour h informs basal hours h−3…h−1.
    public var sampleCount: Int

    public init(hour: Int, pumpRate: Double, rawTunedRate: Double, untuned: Bool, daysMissing: Int = 0, sampleCount: Int = 0) {
        self.hour = hour
        self.pumpRate = pumpRate
        let clamped = LoopGuardrails.clamp(rawTunedRate, to: LoopGuardrails.basalRate)
        self.recommendedRate = clamped.value
        self.changeTier = ChangeTier.classify(pump: pumpRate, tuned: clamped.value)
        self.guardrailStatus = clamped.status
        self.untuned = untuned
        self.daysMissing = daysMissing
        self.sampleCount = sampleCount
    }

    /// Loop's scheduled-basal granularity on typical pumps (Omnipod, most
    /// Medtronic models): 0.05 U/hr.
    public static let loopBasalIncrement = 0.05

    /// The recommended rate rounded to the pump's supported increment — the
    /// value a user can actually enter into Loop. Never rounds an above-zero
    /// recommendation down to zero.
    public func roundedRate(toIncrement increment: Double = Self.loopBasalIncrement) -> Double {
        guard increment.isFinite, increment > 0 else { return recommendedRate }
        var rounded = (recommendedRate / increment).rounded() * increment
        if rounded == 0, recommendedRate > 0 {
            rounded = increment
        }
        // Shave floating-point dust (e.g. 0.15000000000000002).
        return (rounded * 10_000).rounded() / 10_000
    }
}

/// One recommended time block for ISF or carb ratio. The nested parameter uses
/// the same guardrails, unit conversion, and change classification as the
/// original daily summary.
public struct ParameterScheduleRecommendation: Sendable, Equatable, Identifiable {
    public var id: Int { startMinutes }
    /// Minutes since local midnight.
    public var startMinutes: Int
    public var parameter: ParameterRecommendation
    public var untuned: Bool
    /// Usable ISF samples or logged meals behind this block.
    public var evidenceCount: Int
    /// Chained day windows in which this block had no usable evidence.
    public var daysMissing: Int

    public var timeString: String {
        String(format: "%02d:%02d", startMinutes / 60, startMinutes % 60)
    }

    public init(
        startMinutes: Int,
        parameter: ParameterRecommendation,
        untuned: Bool,
        evidenceCount: Int = 0,
        daysMissing: Int = 0
    ) {
        self.startMinutes = startMinutes
        self.parameter = parameter
        self.untuned = untuned
        self.evidenceCount = evidenceCount
        self.daysMissing = daysMissing
    }
}

/// The full tuning recommendation, ready for presentation.
public struct TuningRecommendation: Sendable, Equatable {
    public var sensitivity: ParameterRecommendation
    public var carbRatio: ParameterRecommendation
    public var sensitivitySchedule: [ParameterScheduleRecommendation]
    public var carbRatioSchedule: [ParameterScheduleRecommendation]
    public var basalHours: [BasalHourRecommendation]

    /// Category counts and sample totals for confidence context.
    public var categoryCounts: [DeviationCategory: Int]
    public var totalSamples: Int
    public var daysAnalyzed: Int
    /// The site's own display unit — a sensible default for presentation.
    public var profileGlucoseUnit: GlucoseUnit
    /// Number of day windows actually tuned (chained runs); nil for single runs.
    public var daysTuned: Int?
    /// Therapy settings changes detected inside the window (from the profile
    /// history). The tuner restarted from the applied settings at each.
    public var settingsChanges: [Date]
    /// Samples excluded because a temporary override changed insulin needs.
    public var excludedOverrideSamples: Int

    /// Sum of tuned basal over 24 hours (daily total, U).
    public var tunedDailyBasal: Double { basalHours.reduce(0) { $0 + $1.recommendedRate } }
    public var pumpDailyBasal: Double { basalHours.reduce(0) { $0 + $1.pumpRate } }
    /// Daily total of the increment-rounded rates (what Loop would deliver).
    public func roundedDailyBasal(increment: Double = BasalHourRecommendation.loopBasalIncrement) -> Double {
        basalHours.reduce(0) { $0 + $1.roundedRate(toIncrement: increment) }
    }

    public init(
        from output: TuningOutput,
        daysAnalyzed: Int,
        profileGlucoseUnit: GlucoseUnit = .milligramsPerDeciliter,
        daysMissingByHour: [Int]? = nil,
        daysTuned: Int? = nil,
        settingsChanges: [Date] = [],
        excludedOverrideSamples: Int = 0
    ) {
        precondition(
            output.tunedBasalHourly.count == 24 && output.pumpBasalHourly.count == 24 && output.untunedBasalHours.count == 24,
            "TuningOutput basal arrays must each contain 24 hourly entries"
        )
        let sensitivitySchedule = output.sensitivitySchedule.map { entry in
            ParameterScheduleRecommendation(
                startMinutes: entry.secondsSinceMidnight / 60,
                parameter: ParameterRecommendation(
                    name: "Insulin Sensitivity",
                    unit: "mg/dL/U",
                    pumpValue: entry.pumpValue,
                    rawTunedValue: entry.tunedValue,
                    bounds: LoopGuardrails.sensitivity,
                    isGlucoseDenominated: true
                ),
                untuned: entry.untuned,
                evidenceCount: entry.evidenceCount,
                daysMissing: entry.daysMissing
            )
        }
        let carbRatioSchedule = output.carbRatioSchedule.map { entry in
            ParameterScheduleRecommendation(
                startMinutes: entry.secondsSinceMidnight / 60,
                parameter: ParameterRecommendation(
                    name: "Carb Ratio",
                    unit: "g/U",
                    pumpValue: entry.pumpValue,
                    rawTunedValue: entry.tunedValue,
                    bounds: LoopGuardrails.carbRatio,
                    isGlucoseDenominated: false
                ),
                untuned: entry.untuned,
                evidenceCount: entry.evidenceCount,
                daysMissing: entry.daysMissing
            )
        }
        self.sensitivitySchedule = sensitivitySchedule
        self.carbRatioSchedule = carbRatioSchedule
        var sensitivity = ParameterRecommendation(
            name: "Insulin Sensitivity",
            unit: "mg/dL/U",
            pumpValue: Self.timeWeightedAverage(sensitivitySchedule, value: { $0.parameter.pumpValue }),
            rawTunedValue: output.tunedISF,
            bounds: LoopGuardrails.sensitivity,
            isGlucoseDenominated: true
        )
        Self.applyScheduleSummary(&sensitivity, from: sensitivitySchedule)
        self.sensitivity = sensitivity
        var carbRatio = ParameterRecommendation(
            name: "Carb Ratio",
            unit: "g/U",
            pumpValue: Self.timeWeightedAverage(carbRatioSchedule, value: { $0.parameter.pumpValue }),
            rawTunedValue: output.tunedCarbRatio,
            bounds: LoopGuardrails.carbRatio,
            isGlucoseDenominated: false
        )
        Self.applyScheduleSummary(&carbRatio, from: carbRatioSchedule)
        self.carbRatio = carbRatio
        self.basalHours = (0..<24).map { hour in
            BasalHourRecommendation(
                hour: hour,
                pumpRate: output.pumpBasalHourly[hour],
                rawTunedRate: output.tunedBasalHourly[hour],
                untuned: output.untunedBasalHours[hour],
                daysMissing: daysMissingByHour?[hour] ?? (output.untunedBasalHours[hour] ? 1 : 0),
                sampleCount: output.basalSampleCountByHour[hour]
            )
        }
        self.categoryCounts = output.categoryCounts
        self.totalSamples = output.totalSamples
        self.daysAnalyzed = daysAnalyzed
        self.profileGlucoseUnit = profileGlucoseUnit
        self.daysTuned = daysTuned
        self.settingsChanges = settingsChanges
        self.excludedOverrideSamples = excludedOverrideSamples
    }

    public func recommendedSensitivityDailySchedule() throws -> DailySchedule<Double> {
        try DailySchedule(entries: sensitivitySchedule.map {
            .init(secondsSinceMidnight: $0.startMinutes * 60, value: $0.parameter.recommendedValue)
        })
    }

    public func recommendedCarbRatioDailySchedule() throws -> DailySchedule<Double> {
        try DailySchedule(entries: carbRatioSchedule.map {
            .init(secondsSinceMidnight: $0.startMinutes * 60, value: $0.parameter.recommendedValue)
        })
    }

    private static func timeWeightedAverage(
        _ schedule: [ParameterScheduleRecommendation],
        value: (ParameterScheduleRecommendation) -> Double
    ) -> Double {
        guard !schedule.isEmpty else { return 0 }
        var total = 0.0
        for index in schedule.indices {
            let start = schedule[index].startMinutes
            let end = index + 1 < schedule.count ? schedule[index + 1].startMinutes : 24 * 60
            total += value(schedule[index]) * Double(end - start)
        }
        return total / Double(24 * 60)
    }

    private static func applyScheduleSummary(
        _ summary: inout ParameterRecommendation,
        from schedule: [ParameterScheduleRecommendation]
    ) {
        summary.recommendedValue = timeWeightedAverage(schedule, value: { $0.parameter.recommendedValue })
        summary.percentChange = summary.pumpValue == 0
            ? 0
            : (summary.recommendedValue - summary.pumpValue) / summary.pumpValue * 100
        summary.changeTier = ChangeTier.classify(pump: summary.pumpValue, tuned: summary.recommendedValue)
        if schedule.contains(where: { $0.parameter.guardrailStatus == .atLimit }) {
            summary.guardrailStatus = .atLimit
        } else if schedule.contains(where: { $0.parameter.guardrailStatus == .outsideRecommended }) {
            summary.guardrailStatus = .outsideRecommended
        } else {
            summary.guardrailStatus = .ok
        }
    }
}
