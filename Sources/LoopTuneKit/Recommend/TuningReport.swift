import Foundation

/// Renders a `TuningRecommendation` as a plain-text report resembling the
/// autotune recommendations table, with a mandatory safety disclaimer.
public enum TuningReport {
    public static let disclaimer = """
    ⚠️  LoopTune is an experimental analysis tool, NOT medical advice and NOT a
        medical device. Review every suggestion with your diabetes care team,
        change one setting at a time, and monitor closely. Use at your own risk.
    """

    public static func render(_ recommendation: TuningRecommendation) -> String {
        var lines: [String] = []
        lines.append("LoopTune recommendations")
        lines.append(String(repeating: "=", count: 60))
        lines.append("")
        lines.append("Days analyzed: \(recommendation.daysAnalyzed)   Samples: \(recommendation.totalSamples)")
        lines.append(categoryLine(recommendation.categoryCounts))
        lines.append("")

        lines.append(pad("Parameter", 22) + pad("Pump", 12) + pad("LoopTune", 12) + "Change")
        lines.append(String(repeating: "-", count: 60))
        lines.append(parameterRow(recommendation.sensitivity))
        lines.append(parameterRow(recommendation.carbRatio))
        lines.append("")

        lines.append("Basal schedule [U/hr]")
        lines.append(pad("Hour", 8) + pad("Pump", 12) + pad("LoopTune", 12) + "Flag")
        lines.append(String(repeating: "-", count: 44))
        for hour in recommendation.basalHours where hour.pumpRate != hour.recommendedRate || !hour.untuned {
            lines.append(basalRow(hour))
        }
        lines.append(String(repeating: "-", count: 44))
        lines.append(pad("Total", 8) + pad(fmt(recommendation.pumpDailyBasal), 12) + pad(fmt(recommendation.tunedDailyBasal), 12))
        lines.append("")
        lines.append(disclaimer)
        return lines.joined(separator: "\n")
    }

    private static func categoryLine(_ counts: [DeviationCategory: Int]) -> String {
        let parts = DeviationCategory.allCasesOrdered.map { "\($0.rawValue.uppercased()): \(counts[$0] ?? 0)" }
        return "Categorized — " + parts.joined(separator: "  ")
    }

    private static func parameterRow(_ rec: ParameterRecommendation) -> String {
        let change = String(format: "%+.0f%%", rec.percentChange)
        return pad(rec.name, 22) + pad(fmt(rec.pumpValue), 12) + pad(fmt(rec.recommendedValue), 12) + change + flagSuffix(tier: rec.changeTier, status: rec.guardrailStatus)
    }

    private static func basalRow(_ hour: BasalHourRecommendation) -> String {
        let label = String(format: "%02d:00", hour.hour)
        let flag = hour.untuned ? "(no data)" : tierFlag(hour.changeTier)
        return pad(label, 8) + pad(fmt(hour.pumpRate), 12) + pad(fmt(hour.recommendedRate), 12) + flag
    }

    private static func flagSuffix(tier: ChangeTier, status: LoopGuardrails.Status) -> String {
        var flags: [String] = []
        let tierFlag = tierFlag(tier)
        if !tierFlag.isEmpty { flags.append(tierFlag) }
        switch status {
        case .ok: break
        case .outsideRecommended: flags.append("outside recommended range")
        case .atLimit: flags.append("clamped to Loop limit")
        }
        return flags.isEmpty ? "" : "  " + flags.joined(separator: ", ")
    }

    private static func tierFlag(_ tier: ChangeTier) -> String {
        switch tier {
        case .minimal: return ""
        case .notable: return "△"
        case .large: return "⚠"
        }
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func pad(_ string: String, _ width: Int) -> String {
        string.count >= width ? string : string + String(repeating: " ", count: width - string.count)
    }
}

extension DeviationCategory {
    static let allCasesOrdered: [DeviationCategory] = [.basal, .isf, .csf, .uam]
}
