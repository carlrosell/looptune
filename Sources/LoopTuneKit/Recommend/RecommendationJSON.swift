import Foundation

/// JSON encoding of a `TuningRecommendation` for the CLI `--json` mode and for
/// persistence/golden tests.
public enum RecommendationJSON {
    public static func encode(_ recommendation: TuningRecommendation) throws -> String {
        let dto = RecommendationDTO(recommendation)
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
    }

    var daysAnalyzed: Int
    var totalSamples: Int
    var categoryCounts: [String: Int]
    var sensitivity: Parameter
    var carbRatio: Parameter
    var pumpDailyBasal: Double
    var tunedDailyBasal: Double
    var basal: [BasalHour]

    init(_ recommendation: TuningRecommendation) {
        daysAnalyzed = recommendation.daysAnalyzed
        totalSamples = recommendation.totalSamples
        categoryCounts = Dictionary(uniqueKeysWithValues: recommendation.categoryCounts.map { ($0.key.rawValue, $0.value) })
        sensitivity = Parameter(recommendation.sensitivity)
        carbRatio = Parameter(recommendation.carbRatio)
        pumpDailyBasal = recommendation.pumpDailyBasal
        tunedDailyBasal = recommendation.tunedDailyBasal
        basal = recommendation.basalHours.map(BasalHour.init)
    }
}

private extension RecommendationDTO.Parameter {
    init(_ rec: ParameterRecommendation) {
        self.init(
            name: rec.name,
            unit: rec.unit,
            pump: rec.pumpValue,
            recommended: rec.recommendedValue,
            rawTuned: rec.rawTunedValue,
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
            untuned: rec.untuned
        )
    }
}
