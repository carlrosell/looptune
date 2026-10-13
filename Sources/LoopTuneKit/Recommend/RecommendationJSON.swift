import Foundation

/// JSON encoding of a `TuningRecommendation` for the CLI `--json` mode and for
/// persistence/golden tests.
public enum RecommendationJSON {
    public static func encode(
        _ recommendation: TuningRecommendation,
        displayUnit: GlucoseUnit? = nil,
        basalIncrement: Double = BasalHourRecommendation.loopBasalIncrement
    ) throws -> String {
        let unit = displayUnit ?? recommendation.profileGlucoseUnit
        let dto = RecommendationDTO(recommendation, displayUnit: unit, basalIncrement: basalIncrement)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(dto)
        return String(decoding: data, as: UTF8.self)
    }
}

struct RecommendationDTO: Encodable {
    struct Parameter: Encodable {
        var name: String
        var unit: String
        var pump: Double
        var recommended: Double
        var rawTuned: Double
        var percentChange: Double
        var changeTier: String
        var guardrailStatus: String
    }
    struct BasalHour: Encodable {
        var hour: Int
        var pump: Double
        /// Unrounded tuned rate (diagnostic); `recommendedRounded` is entered.
        /// With insufficient data, both are the pump rate.
        var recommended: Double
        var recommendedRounded: Double
        /// Tier and status describe `recommendedRounded`.
        var changeTier: String
        var guardrailStatus: String
        var untuned: Bool
        var daysMissing: Int
        var sampleCount: Int
        /// `tuned`, `insufficientData`, or `carriedForward` (ADR 0011).
        var evidenceStatus: String
        /// The alternative to the pump rate for an hour with insufficient data.
        var interpolated: InterpolatedBasal?
        var note: String?
    }
    struct InterpolatedBasal: Encodable {
        var recommended: Double
        var recommendedRounded: Double
        /// Relative to the pump rate; describes this alternative only.
        var changeTier: String
        var guardrailStatus: String
        var from: [String]
        var fromHours: [Int]
    }
    struct InterpolatedParameter: Encodable {
        var recommended: Double
        var rawTuned: Double
        /// Relative to the pump value; describes this alternative only.
        var percentChange: Double
        var changeTier: String
        var guardrailStatus: String
        var from: [String]
        var fromSecondsSinceMidnight: [Int]
    }
    struct ParameterScheduleEntry: Encodable {
        var time: String
        var secondsSinceMidnight: Int
        var startMinutes: Int
        var unit: String
        var pump: Double
        var recommended: Double
        var rawTuned: Double
        var percentChange: Double
        var changeTier: String
        var guardrailStatus: String
        var untuned: Bool
        var daysMissing: Int
        var evidenceCount: Int
        /// `tuned`, `insufficientData`, or `carriedForward` (ADR 0011). With
        /// insufficient data, `recommended` is the pump value.
        var evidenceStatus: String
        /// The alternative to the pump value for a block with insufficient data.
        var interpolated: InterpolatedParameter?
        var note: String?
    }

    var daysAnalyzed: Int
    var daysTuned: Int?
    var totalSamples: Int
    var excludedOverrideSamples: Int
    var displayUnit: String
    var disclaimer: String
    var settingsChanges: [String]
    var categoryCounts: [String: Int]
    var sensitivity: Parameter
    var carbRatio: Parameter
    var sensitivitySchedule: [ParameterScheduleEntry]
    var carbRatioSchedule: [ParameterScheduleEntry]
    var pumpDailyBasal: Double
    var tunedDailyBasal: Double
    var roundedDailyBasal: Double
    var basalIncrement: Double
    var basal: [BasalHour]
    var loopBasalSchedule: [LoopEntry]

    struct LoopEntry: Encodable {
        var time: String
        var startMinutes: Int
        /// With insufficient data, the pump rate.
        var rate: Double
        var evidenceStatus: String
        var interpolatedRate: Double?
        var interpolatedFrom: [String]?
        var note: String?
    }

    init(_ recommendation: TuningRecommendation, displayUnit: GlucoseUnit, basalIncrement: Double) {
        daysAnalyzed = recommendation.daysAnalyzed
        daysTuned = recommendation.daysTuned
        totalSamples = recommendation.totalSamples
        excludedOverrideSamples = recommendation.excludedOverrideSamples
        self.displayUnit = displayUnit.shortLabel
        disclaimer = TuningReport.disclaimer
        let dayFormatter = ISO8601DateFormatter()
        dayFormatter.formatOptions = [.withInternetDateTime]
        settingsChanges = recommendation.settingsChanges.map { dayFormatter.string(from: $0) }
        categoryCounts = Dictionary(uniqueKeysWithValues: recommendation.categoryCounts.map { ($0.key.rawValue, $0.value) })
        sensitivity = Parameter(recommendation.sensitivity, in: displayUnit)
        carbRatio = Parameter(recommendation.carbRatio, in: displayUnit)
        sensitivitySchedule = recommendation.sensitivitySchedule.map {
            ParameterScheduleEntry($0, in: displayUnit)
        }
        carbRatioSchedule = recommendation.carbRatioSchedule.map {
            ParameterScheduleEntry($0, in: displayUnit)
        }
        pumpDailyBasal = recommendation.pumpDailyBasal
        tunedDailyBasal = recommendation.tunedDailyBasal
        roundedDailyBasal = recommendation.roundedDailyBasal(increment: basalIncrement)
        self.basalIncrement = basalIncrement
        basal = recommendation.basalHours.map { BasalHour($0, increment: basalIncrement) }
        loopBasalSchedule = recommendation.loopBasalSchedule(increment: basalIncrement).map {
            LoopEntry(
                time: $0.timeString,
                startMinutes: $0.startMinutes,
                rate: $0.rate,
                evidenceStatus: $0.evidenceStatus.rawValue,
                interpolatedRate: $0.insufficientEvidence?.interpolated,
                interpolatedFrom: $0.insufficientEvidence.flatMap { $0.interpolated == nil ? nil : $0.sourceTimes },
                note: $0.insufficientEvidence?.note
            )
        }
    }
}

private extension RecommendationDTO.ParameterScheduleEntry {
    init(_ entry: ParameterScheduleRecommendation, in unit: GlucoseUnit) {
        let rec = entry.parameter
        self.init(
            time: entry.timeString,
            secondsSinceMidnight: entry.secondsSinceMidnight,
            startMinutes: entry.startMinutes,
            unit: rec.unitLabel(in: unit),
            pump: rec.pumpValue(in: unit),
            recommended: rec.recommendedValue(in: unit),
            rawTuned: rec.rawTunedValue(in: unit),
            percentChange: rec.percentChange,
            changeTier: rec.changeTier.rawValue,
            guardrailStatus: rec.guardrailStatus.rawValue,
            untuned: entry.untuned,
            daysMissing: entry.daysMissing,
            evidenceCount: entry.evidenceCount,
            evidenceStatus: entry.evidenceStatus.rawValue,
            interpolated: entry.insufficientEvidence.flatMap { evidence in
                evidence.interpolated.map { alternative in
                    RecommendationDTO.InterpolatedParameter(
                        recommended: alternative.recommendedValue(in: unit),
                        rawTuned: alternative.rawTunedValue(in: unit),
                        percentChange: alternative.percentChange,
                        changeTier: alternative.changeTier.rawValue,
                        guardrailStatus: alternative.guardrailStatus.rawValue,
                        from: evidence.sourceTimes,
                        fromSecondsSinceMidnight: evidence.sources
                    )
                }
            },
            note: entry.insufficientEvidence?.note
        )
    }
}

private extension RecommendationDTO.Parameter {
    init(_ rec: ParameterRecommendation, in unit: GlucoseUnit) {
        self.init(
            name: rec.name,
            unit: rec.unitLabel(in: unit),
            pump: rec.pumpValue(in: unit),
            recommended: rec.recommendedValue(in: unit),
            rawTuned: rec.rawTunedValue(in: unit),
            percentChange: rec.percentChange,
            changeTier: rec.changeTier.rawValue,
            guardrailStatus: rec.guardrailStatus.rawValue
        )
    }
}

private extension RecommendationDTO.BasalHour {
    init(_ rec: BasalHourRecommendation, increment: Double) {
        self.init(
            hour: rec.hour,
            pump: rec.pumpRate,
            recommended: rec.recommendedRate,
            recommendedRounded: rec.roundedRate(toIncrement: increment),
            changeTier: rec.changeTier(increment: increment).rawValue,
            guardrailStatus: rec.guardrailStatus(increment: increment).rawValue,
            untuned: rec.untuned,
            daysMissing: rec.daysMissing,
            sampleCount: rec.sampleCount,
            evidenceStatus: rec.evidenceStatus.rawValue,
            interpolated: rec.insufficientEvidence.flatMap { evidence in
                evidence.interpolated.map { rate in
                    RecommendationDTO.InterpolatedBasal(
                        recommended: rate,
                        recommendedRounded: rec.interpolatedRoundedRate(toIncrement: increment) ?? rate,
                        changeTier: (rec.interpolatedChangeTier(increment: increment) ?? .minimal).rawValue,
                        guardrailStatus: (rec.interpolatedGuardrailStatus(increment: increment) ?? .ok).rawValue,
                        from: evidence.sourceTimes,
                        fromHours: evidence.sources.map { $0 / 3600 }
                    )
                }
            },
            note: rec.insufficientEvidence?.note
        )
    }
}
