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

    /// The pump value in the display unit at the precision it was stored
    /// with, up to three decimals, for blocks where it is one of the user's
    /// choices. A value converted to mmol/L keeps the usual two decimals.
    public func formattedPumpValue(in displayUnit: GlucoseUnit) -> String {
        let value = pumpValue(in: displayUnit)
        let standard = decimals(in: displayUnit)
        let converted = isGlucoseDenominated && displayUnit == .millimolesPerLiter
        return PumpValueFormat.string(value, decimals: standard...max(standard, 3), fallback: converted ? standard : 3)
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
    /// The tuned rate inside the limits, before rounding to a pump increment.
    /// Diagnostic only: users enter `roundedRate(toIncrement:)`.
    public var recommendedRate: Double
    /// Loop guardrail status of `recommendedRate`. Use
    /// `guardrailStatus(increment:)` for the value entered into Loop.
    public var guardrailStatus: LoopGuardrails.Status
    /// True when no basal evidence under the final settings informed this hour.
    public var untuned: Bool
    /// Set when this hour's own evidence was insufficient (ADR 0011). Its
    /// `recommendedRate` is then the pump rate, and the alternative is the
    /// rate interpolated from the nearest hours with evidence, inside this
    /// hour's limits and before rounding. `nil` for tuned hours and for runs
    /// saved before ADR 0011.
    public var insufficientEvidence: InsufficientEvidence<Double>?
    /// Day windows in which this hour received no tuning data (confidence:
    /// higher = less real data behind the recommendation for this hour).
    public var daysMissing: Int
    /// Basal-categorized evidence, in five-minute intervals, that informed this
    /// scheduled basal hour across the window. A deviation observed at hour h
    /// informs basal hours h−3…h−1.
    public var sampleCount: Int
    /// Lowest rate the recommendation may take: the pump-relative tuning floor
    /// or Loop's absolute minimum, whichever is higher.
    public var minimumRate: Double
    /// Highest rate the recommendation may take: the pump-relative tuning cap
    /// or Loop's absolute maximum, whichever is lower. Below `minimumRate` when
    /// no rate is permitted, as for a zero pump rate.
    public var maximumRate: Double

    /// - Parameter caps: the pump-relative caps the tuner applied. The
    ///   recommended and rounded rates stay inside them.
    public init(
        hour: Int,
        pumpRate: Double,
        rawTunedRate: Double,
        untuned: Bool,
        daysMissing: Int = 0,
        sampleCount: Int = 0,
        caps: TuningCaps = TuningCaps()
    ) {
        self.hour = hour
        self.pumpRate = pumpRate
        let limits = Self.limits(pumpRate: pumpRate, caps: caps)
        self.minimumRate = limits.minimum
        self.maximumRate = limits.maximum
        let clamped = Self.limited(rawTunedRate, pumpRate: pumpRate, minimum: limits.minimum, maximum: limits.maximum)
        self.recommendedRate = clamped.rate
        self.guardrailStatus = clamped.status
        self.untuned = untuned
        self.daysMissing = daysMissing
        self.sampleCount = sampleCount
    }

    /// An hour without sufficient evidence of its own (ADR 0011). The
    /// recommended rate is the pump rate. `interpolatedRate`, when supplied,
    /// is limited like a tuned rate and offered beside it.
    public init(
        hour: Int,
        pumpRate: Double,
        interpolatedRate: Double?,
        sources: [Int],
        daysMissing: Int = 0,
        sampleCount: Int = 0,
        caps: TuningCaps = TuningCaps()
    ) {
        self.init(
            hour: hour,
            pumpRate: pumpRate,
            rawTunedRate: pumpRate,
            untuned: true,
            daysMissing: daysMissing,
            sampleCount: sampleCount,
            caps: caps
        )
        let alternative = interpolatedRate.map {
            Self.round3(Self.limited($0, pumpRate: pumpRate, minimum: minimumRate, maximum: maximumRate).rate)
        }
        self.insufficientEvidence = InsufficientEvidence(interpolated: alternative, sources: sources)
    }

    /// `rate` inside Loop's absolute limits and `minimum...maximum`. When no
    /// rate satisfies both, the pump rate is kept. This preserves zero rates
    /// instead of raising them to 0.05.
    private static func limited(
        _ rate: Double,
        pumpRate: Double,
        minimum: Double,
        maximum: Double
    ) -> (rate: Double, status: LoopGuardrails.Status) {
        guard minimum <= maximum else { return (pumpRate, status(of: pumpRate)) }
        let clamped = LoopGuardrails.clamp(rate, to: LoopGuardrails.basalRate)
        return (min(max(clamped.value, minimum), maximum), clamped.status)
    }

    private static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    /// Whether this hour's evidence supports its recommended rate.
    public var evidenceStatus: BlockEvidenceStatus {
        if insufficientEvidence != nil { return .insufficientData }
        return untuned ? .carriedForward : .tuned
    }

    static func limits(pumpRate: Double, caps: TuningCaps) -> (minimum: Double, maximum: Double) {
        let bounds = LoopGuardrails.basalRate
        return (
            max(pumpRate * caps.autotuneMin, bounds.absoluteMin),
            min(pumpRate * caps.autotuneMax, bounds.absoluteMax)
        )
    }

    static func status(of rate: Double) -> LoopGuardrails.Status {
        let bounds = LoopGuardrails.basalRate
        return rate < bounds.recommendedMin || rate > bounds.recommendedMax ? .outsideRecommended : .ok
    }

    /// Change class of the rate entered into Loop at the default increment.
    public var changeTier: ChangeTier { changeTier(increment: Self.loopBasalIncrement) }

    /// Change class of `roundedRate(toIncrement:)`, the rate entered into
    /// Loop, so an hour whose final rate is unchanged reports `.minimal`.
    public func changeTier(increment: Double) -> ChangeTier {
        ChangeTier.classify(pump: pumpRate, tuned: roundedRate(toIncrement: increment))
    }

    /// The interpolated alternative rounded like a recommendation, or `nil`
    /// when the hour has evidence or no alternative.
    public func interpolatedRoundedRate(toIncrement increment: Double = Self.loopBasalIncrement) -> Double? {
        insufficientEvidence?.interpolated.map { rounded($0, increment: increment) }
    }

    /// Change class of the rounded interpolated alternative relative to the
    /// pump rate. It describes the alternative, not a tuned change.
    public func interpolatedChangeTier(increment: Double = Self.loopBasalIncrement) -> ChangeTier? {
        interpolatedRoundedRate(toIncrement: increment).map { ChangeTier.classify(pump: pumpRate, tuned: $0) }
    }

    /// Loop guardrail status of the rounded interpolated alternative.
    public func interpolatedGuardrailStatus(increment: Double = Self.loopBasalIncrement) -> LoopGuardrails.Status? {
        interpolatedRoundedRate(toIncrement: increment).map(Self.status(of:))
    }

    /// Loop guardrail status of `roundedRate(toIncrement:)`. It is `.atLimit`
    /// only when the entered rate is the Loop limit `recommendedRate` was
    /// clamped to.
    public func guardrailStatus(increment: Double) -> LoopGuardrails.Status {
        let rate = roundedRate(toIncrement: increment)
        return rate == recommendedRate ? guardrailStatus : Self.status(of: rate)
    }

    /// A pump rate at the precision it was stored with, two or three
    /// decimals, for hours where it is one of the user's choices.
    public static func formattedPumpRate(_ rate: Double) -> String {
        PumpValueFormat.string(rate, decimals: 2...3, fallback: 3)
    }

    /// Loop's scheduled-basal granularity on typical pumps (Omnipod, most
    /// Medtronic models): 0.05 U/hr.
    public static let loopBasalIncrement = 0.05

    /// The value a user can actually enter into Loop: the recommended rate
    /// rounded to the nearest pump increment between `minimumRate` and
    /// `maximumRate`. When no increment lies in that range, the pump rate is
    /// kept unchanged. An hour with insufficient data keeps the pump rate.
    public func roundedRate(toIncrement increment: Double = Self.loopBasalIncrement) -> Double {
        guard insufficientEvidence == nil else { return pumpRate }
        return rounded(recommendedRate, increment: increment)
    }

    private func rounded(_ rate: Double, increment: Double) -> Double {
        guard increment.isFinite, increment > 0 else { return rate }
        // Tolerate floating-point error in limits such as 0.15 × 1.2.
        let tolerance = 1e-9
        let lowestStep = (minimumRate / increment - tolerance).rounded(.up)
        let highestStep = (maximumRate / increment + tolerance).rounded(.down)
        guard lowestStep <= highestStep else { return pumpRate }
        let step = min(max((rate / increment).rounded(), lowestStep), highestStep)
        // Shave floating-point dust (e.g. 0.15000000000000002).
        return (step * increment * 10_000).rounded() / 10_000
    }
}

/// One recommended time block for ISF or carb ratio. The nested parameter uses
/// the same guardrails, unit conversion, and change classification as the
/// original daily summary.
public struct ParameterScheduleRecommendation: Sendable, Equatable, Identifiable {
    public var id: Int { secondsSinceMidnight }
    /// Full schedule offset in seconds since local midnight.
    public var secondsSinceMidnight: Int
    /// Whole minutes since local midnight, for Loop-style display and JSON
    /// compatibility. Schedule identity and reconstruction use seconds.
    public var startMinutes: Int { secondsSinceMidnight / 60 }
    public var parameter: ParameterRecommendation
    /// True when this block had too little usable evidence under the final
    /// settings.
    public var untuned: Bool
    /// Usable ISF samples or logged meals behind this block.
    public var evidenceCount: Int
    /// Chained day windows in which this block had no usable evidence.
    public var daysMissing: Int
    /// Set when this block's own evidence was insufficient (ADR 0011). Its
    /// `parameter` then recommends the pump value, and the alternative holds
    /// the value interpolated from the nearest blocks with evidence. `nil`
    /// for tuned blocks and for runs saved before ADR 0011.
    public var insufficientEvidence: InsufficientEvidence<ParameterRecommendation>?

    public var timeString: String {
        InsufficientEvidence<ParameterRecommendation>.timeString(secondsSinceMidnight)
    }

    /// Whether this block's evidence supports its recommended value.
    public var evidenceStatus: BlockEvidenceStatus {
        if insufficientEvidence != nil { return .insufficientData }
        return untuned ? .carriedForward : .tuned
    }

    public init(
        secondsSinceMidnight: Int,
        parameter: ParameterRecommendation,
        untuned: Bool,
        evidenceCount: Int = 0,
        daysMissing: Int = 0,
        insufficientEvidence: InsufficientEvidence<ParameterRecommendation>? = nil
    ) {
        self.secondsSinceMidnight = secondsSinceMidnight
        self.parameter = parameter
        self.untuned = untuned || insufficientEvidence != nil
        self.evidenceCount = evidenceCount
        self.daysMissing = daysMissing
        self.insufficientEvidence = insufficientEvidence
    }

    /// Compatibility initializer for callers that only have minute offsets.
    public init(
        startMinutes: Int,
        parameter: ParameterRecommendation,
        untuned: Bool,
        evidenceCount: Int = 0,
        daysMissing: Int = 0
    ) {
        self.init(
            secondsSinceMidnight: startMinutes * 60,
            parameter: parameter,
            untuned: untuned,
            evidenceCount: evidenceCount,
            daysMissing: daysMissing
        )
    }

    public func evidenceDescription(_ evidenceName: String) -> String {
        var description: String
        if untuned && evidenceCount == 0 {
            description = "no data"
        } else if untuned && insufficientEvidence == nil {
            description = "\(evidenceCount) \(evidenceName), unchanged"
        } else {
            description = "\(evidenceCount) \(evidenceName)"
        }
        if daysMissing > 0 {
            description += ", \(daysMissing)d missing"
        }
        return description
    }
}

/// The full tuning recommendation, ready for presentation.
public struct TuningRecommendation: Sendable, Equatable {
    public var sensitivity: ParameterRecommendation
    public var carbRatio: ParameterRecommendation
    public var sensitivitySchedule: [ParameterScheduleRecommendation]
    public var carbRatioSchedule: [ParameterScheduleRecommendation]
    public var basalHours: [BasalHourRecommendation]

    /// Category counts and sample totals for confidence context. Every
    /// evidence count is in five-minute intervals of CGM time, not readings.
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
    /// Evidence, in five-minute intervals, excluded because a temporary
    /// override changed insulin needs.
    public var excludedOverrideSamples: Int

    /// Sum of tuned basal over 24 hours (daily total, U).
    public var tunedDailyBasal: Double { basalHours.reduce(0) { $0 + $1.recommendedRate } }
    public var pumpDailyBasal: Double { basalHours.reduce(0) { $0 + $1.pumpRate } }
    /// Daily total of the increment-rounded rates (what Loop would deliver).
    public func roundedDailyBasal(increment: Double = BasalHourRecommendation.loopBasalIncrement) -> Double {
        basalHours.reduce(0) { $0 + $1.roundedRate(toIncrement: increment) }
    }

    /// - Parameters:
    ///   - daysMissingByHour: when non-nil, 24 entries indexed by local hour.
    ///   - caps: the tuner's pump-relative caps. Final basal rates stay inside
    ///     them.
    /// - Throws: `TuningOutput.HourlyCountError` when an hourly collection does
    ///   not hold 24 entries, including values set after the output was
    ///   initialized, and `TuningOutput.InitializationError` for an invalid
    ///   ISF or carb-ratio schedule.
    public init(
        from output: TuningOutput,
        daysAnalyzed: Int,
        profileGlucoseUnit: GlucoseUnit = .milligramsPerDeciliter,
        daysMissingByHour: [Int]? = nil,
        daysTuned: Int? = nil,
        settingsChanges: [Date] = [],
        excludedOverrideSamples: Int = 0,
        caps: TuningCaps = TuningCaps()
    ) throws {
        try output.validateHourlyCounts(daysMissingByHour: daysMissingByHour)
        try TuningOutput.validate(
            output.sensitivitySchedule.map(\.secondsSinceMidnight),
            parameter: .sensitivity
        )
        try TuningOutput.validate(
            output.carbRatioSchedule.map(\.secondsSinceMidnight),
            parameter: .carbRatio
        )
        let sensitivitySchedule = Self.scheduleRecommendations(
            output.sensitivitySchedule,
            name: "Insulin Sensitivity",
            unit: "mg/dL/U",
            bounds: LoopGuardrails.sensitivity,
            isGlucoseDenominated: true,
            // ISF caps are inverted: a lower sensitivity ratio raises ISF.
            limits: { pump in (pump / caps.autotuneMax, pump / caps.autotuneMin) }
        )
        let carbRatioSchedule = Self.scheduleRecommendations(
            output.carbRatioSchedule,
            name: "Carb Ratio",
            unit: "g/U",
            bounds: LoopGuardrails.carbRatio,
            isGlucoseDenominated: false,
            limits: { pump in (pump * caps.autotuneMin, pump * caps.autotuneMax) }
        )
        self.sensitivitySchedule = sensitivitySchedule
        self.carbRatioSchedule = carbRatioSchedule
        var sensitivity = ParameterRecommendation(
            name: "Insulin Sensitivity",
            unit: "mg/dL/U",
            pumpValue: Self.timeWeightedAverage(sensitivitySchedule, value: { $0.parameter.pumpValue }),
            rawTunedValue: Self.timeWeightedAverage(sensitivitySchedule, value: { $0.parameter.rawTunedValue }),
            bounds: LoopGuardrails.sensitivity,
            isGlucoseDenominated: true
        )
        Self.applyScheduleSummary(&sensitivity, from: sensitivitySchedule)
        self.sensitivity = sensitivity
        var carbRatio = ParameterRecommendation(
            name: "Carb Ratio",
            unit: "g/U",
            pumpValue: Self.timeWeightedAverage(carbRatioSchedule, value: { $0.parameter.pumpValue }),
            rawTunedValue: Self.timeWeightedAverage(carbRatioSchedule, value: { $0.parameter.rawTunedValue }),
            bounds: LoopGuardrails.carbRatio,
            isGlucoseDenominated: false
        )
        Self.applyScheduleSummary(&carbRatio, from: carbRatioSchedule)
        self.carbRatio = carbRatio
        let tunedHours = (0..<24).map { hour -> BasalHourRecommendation? in
            guard !output.untunedBasalHours[hour] else { return nil }
            return BasalHourRecommendation(
                hour: hour,
                pumpRate: output.pumpBasalHourly[hour],
                rawTunedRate: output.tunedBasalHourly[hour],
                untuned: false,
                daysMissing: daysMissingByHour?[hour] ?? 0,
                sampleCount: output.basalSampleCountByHour[hour],
                caps: caps
            )
        }
        let hourStarts = (0..<24).map { $0 * 3600 }
        self.basalHours = (0..<24).map { hour in
            if let tuned = tunedHours[hour] { return tuned }
            // The output's rate for an hour without evidence is the value
            // carried into chained replay, never a recommendation.
            let interpolation = ScheduleInterpolation.interpolate(
                at: hour,
                starts: hourStarts,
                values: tunedHours.map { $0?.recommendedRate }
            )
            return BasalHourRecommendation(
                hour: hour,
                pumpRate: output.pumpBasalHourly[hour],
                interpolatedRate: interpolation?.value,
                sources: interpolation?.sources ?? [],
                daysMissing: daysMissingByHour?[hour] ?? 1,
                sampleCount: output.basalSampleCountByHour[hour],
                caps: caps
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

    /// How many blocks of each schedule had insufficient data (ADR 0011).
    public var insufficientData: InsufficientDataSummary {
        InsufficientDataSummary(
            basalHours: basalHours.filter { $0.insufficientEvidence != nil }.count,
            sensitivityBlocks: sensitivitySchedule.filter { $0.insufficientEvidence != nil }.count,
            carbRatioBlocks: carbRatioSchedule.filter { $0.insufficientEvidence != nil }.count,
            totalBasalHours: basalHours.count,
            totalSensitivityBlocks: sensitivitySchedule.count,
            totalCarbRatioBlocks: carbRatioSchedule.count
        )
    }

    public func recommendedSensitivityDailySchedule() throws -> DailySchedule<Double> {
        try DailySchedule(entries: sensitivitySchedule.map {
            .init(secondsSinceMidnight: $0.secondsSinceMidnight, value: $0.parameter.recommendedValue)
        })
    }

    public func recommendedCarbRatioDailySchedule() throws -> DailySchedule<Double> {
        try DailySchedule(entries: carbRatioSchedule.map {
            .init(secondsSinceMidnight: $0.secondsSinceMidnight, value: $0.parameter.recommendedValue)
        })
    }

    /// Builds one parameter's schedule. A block without sufficient evidence
    /// recommends its pump value and offers the value interpolated from the
    /// nearest evidence-backed blocks, inside its own pump-relative `limits`
    /// and Loop's guardrails (ADR 0011). The output's value for such a block
    /// is what chained replay carried forward and is never used.
    private static func scheduleRecommendations(
        _ entries: [ScheduleTuningOutput],
        name: String,
        unit: String,
        bounds: LoopGuardrails.Bounds,
        isGlucoseDenominated: Bool,
        limits: (Double) -> (lower: Double, upper: Double)
    ) -> [ParameterScheduleRecommendation] {
        func parameter(pump: Double, raw: Double) -> ParameterRecommendation {
            ParameterRecommendation(
                name: name,
                unit: unit,
                pumpValue: pump,
                rawTunedValue: raw,
                bounds: bounds,
                isGlucoseDenominated: isGlucoseDenominated
            )
        }
        let tuned = entries.map { entry in
            entry.untuned ? nil : parameter(pump: entry.pumpValue, raw: entry.tunedValue)
        }
        let starts = entries.map(\.secondsSinceMidnight)
        return entries.indices.map { index in
            let entry = entries[index]
            if let tuned = tuned[index] {
                return ParameterScheduleRecommendation(
                    secondsSinceMidnight: entry.secondsSinceMidnight,
                    parameter: tuned,
                    untuned: false,
                    evidenceCount: entry.evidenceCount,
                    daysMissing: entry.daysMissing
                )
            }
            let interpolation = ScheduleInterpolation.interpolate(
                at: index,
                starts: starts,
                values: tuned.map { $0?.recommendedValue }
            )
            let alternative = interpolation.map { interpolation in
                let (lower, upper) = limits(entry.pumpValue)
                let capped = TuningMath.clamp(interpolation.value, lower, upper)
                return parameter(pump: entry.pumpValue, raw: (capped * 1000).rounded() / 1000)
            }
            return ParameterScheduleRecommendation(
                secondsSinceMidnight: entry.secondsSinceMidnight,
                parameter: parameter(pump: entry.pumpValue, raw: entry.pumpValue),
                untuned: true,
                evidenceCount: entry.evidenceCount,
                daysMissing: entry.daysMissing,
                insufficientEvidence: InsufficientEvidence(
                    interpolated: alternative,
                    sources: interpolation?.sources ?? []
                )
            )
        }
    }

    private static func timeWeightedAverage(
        _ schedule: [ParameterScheduleRecommendation],
        value: (ParameterScheduleRecommendation) -> Double
    ) -> Double {
        guard !schedule.isEmpty else { return 0 }
        var total = 0.0
        for index in schedule.indices {
            let start = schedule[index].secondsSinceMidnight
            let end = index + 1 < schedule.count ? schedule[index + 1].secondsSinceMidnight : 86_400
            total += value(schedule[index]) * Double(end - start)
        }
        return total / 86_400
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

/// Counts of blocks without sufficient evidence of their own, for warnings.
public struct InsufficientDataSummary: Sendable, Equatable {
    public var basalHours: Int
    public var sensitivityBlocks: Int
    public var carbRatioBlocks: Int
    /// Block counts of each schedule. Zero when unknown.
    public var totalBasalHours: Int
    public var totalSensitivityBlocks: Int
    public var totalCarbRatioBlocks: Int

    public init(
        basalHours: Int,
        sensitivityBlocks: Int,
        carbRatioBlocks: Int,
        totalBasalHours: Int = 0,
        totalSensitivityBlocks: Int = 0,
        totalCarbRatioBlocks: Int = 0
    ) {
        self.basalHours = basalHours
        self.sensitivityBlocks = sensitivityBlocks
        self.carbRatioBlocks = carbRatioBlocks
        self.totalBasalHours = totalBasalHours
        self.totalSensitivityBlocks = totalSensitivityBlocks
        self.totalCarbRatioBlocks = totalCarbRatioBlocks
    }

    public var isEmpty: Bool { basalHours == 0 && sensitivityBlocks == 0 && carbRatioBlocks == 0 }

    /// Whether no block of the schedule had evidence, so its daily summary
    /// repeats the pump values and is not a recommendation.
    public var allBasalHours: Bool { basalHours > 0 && basalHours == totalBasalHours }
    public var allSensitivityBlocks: Bool { sensitivityBlocks > 0 && sensitivityBlocks == totalSensitivityBlocks }
    public var allCarbRatioBlocks: Bool { carbRatioBlocks > 0 && carbRatioBlocks == totalCarbRatioBlocks }

    /// For example "3 basal hours, 1 ISF block".
    public var description: String {
        func count(_ value: Int, _ singular: String, _ plural: String) -> String? {
            value == 0 ? nil : "\(value) \(value == 1 ? singular : plural)"
        }
        return [
            count(basalHours, "basal hour", "basal hours"),
            count(sensitivityBlocks, "ISF block", "ISF blocks"),
            count(carbRatioBlocks, "carb-ratio block", "carb-ratio blocks"),
        ].compactMap { $0 }.joined(separator: ", ")
    }
}
