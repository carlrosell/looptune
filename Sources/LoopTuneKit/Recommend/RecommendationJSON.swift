import Foundation

/// JSON encoding of a `TuningRecommendation` for the CLI `--json` mode and for
/// persistence/golden tests.
public enum RecommendationJSON {
    public static func encode(_ recommendation: TuningRecommendation, displayUnit: GlucoseUnit? = nil) throws -> String {
        let unit = displayUnit ?? recommendation.profileGlucoseUnit
        let dto = RecommendationDTO(recommendation, displayUnit: unit)
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
        var recommended: Double
        var changeTier: String
        var guardrailStatus: String
        var untuned: Bool
        var daysMissing: Int
        var sampleCount: Int
    }

    var daysAnalyzed: Int
    var totalSamples: Int
    var displayUnit: String
    var categoryCounts: [String: Int]
    var sensitivity: Parameter
    var carbRatio: Parameter
    var pumpDailyBasal: Double
    var tunedDailyBasal: Double
    var basal: [BasalHour]

    init(_ recommendation: TuningRecommendation, displayUnit: GlucoseUnit) {
        daysAnalyzed = recommendation.daysAnalyzed
        totalSamples = recommendation.totalSamples
        self.displayUnit = displayUnit.shortLabel
        categoryCounts = Dictionary(uniqueKeysWithValues: recommendation.categoryCounts.map { ($0.key.rawValue, $0.value) })
        sensitivity = Parameter(recommendation.sensitivity, in: displayUnit)
        carbRatio = Parameter(recommendation.carbRatio, in: displayUnit)
        pumpDailyBasal = recommendation.pumpDailyBasal
        tunedDailyBasal = recommendation.tunedDailyBasal
        basal = recommendation.basalHours.map(BasalHour.init)
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
    init(_ rec: BasalHourRecommendation) {
        self.init(
            hour: rec.hour,
            pump: rec.pumpRate,
            recommended: rec.recommendedRate,
            changeTier: rec.changeTier.rawValue,
            guardrailStatus: rec.guardrailStatus.rawValue,
            untuned: rec.untuned,
            daysMissing: rec.daysMissing,
            sampleCount: rec.sampleCount
        )
    }
}
