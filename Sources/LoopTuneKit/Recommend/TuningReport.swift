import Foundation

/// Renders a `TuningRecommendation` as a plain-text report resembling the
/// autotune recommendations table, with a mandatory safety disclaimer.
public enum TuningReport {
    public static let disclaimer = """
    ⚠️  LoopTune is an experimental analysis tool, NOT medical advice and NOT a
        medical device. Review every suggestion with your diabetes care team,
        change one setting at a time, and monitor closely. Use at your own risk.
    """

    /// Render the report. `displayUnit` defaults to the site's own glucose unit;
    /// glucose-denominated values (ISF) are shown in that unit. `basalIncrement`
    /// is the pump's scheduled-basal granularity for the Rounded column.
    public static func render(
        _ recommendation: TuningRecommendation,
        displayUnit: GlucoseUnit? = nil,
        basalIncrement: Double = BasalHourRecommendation.loopBasalIncrement
    ) -> String {
        let unit = displayUnit ?? recommendation.profileGlucoseUnit
        var lines: [String] = []
        lines.append("LoopTune recommendations")
        lines.append(String(repeating: "=", count: 60))
        lines.append("")
        lines.append("Days analyzed: \(recommendation.daysAnalyzed)   Samples: \(recommendation.totalSamples)   Units: \(unit.shortLabel)")
        lines.append(categoryLine(recommendation.categoryCounts))
        if !recommendation.settingsChanges.isEmpty {
            let dates = recommendation.settingsChanges.map { Self.dayFormatter.string(from: $0) }.joined(separator: ", ")
            lines.append("Settings changed during the window (\(dates)); the analysis restarted from your applied settings at each change.")
        }
        if recommendation.excludedOverrideSamples > 0 {
            lines.append("\(recommendation.excludedOverrideSamples) samples during insulin-needs overrides were excluded from tuning.")
        }
        lines.append("")

        lines.append(pad("Parameter", 22) + pad("Pump", 14) + pad("LoopTune", 14) + "Change")
        lines.append(String(repeating: "-", count: 60))
        lines.append(parameterRow(recommendation.sensitivity, unit: unit))
        lines.append(parameterRow(recommendation.carbRatio, unit: unit))
        lines.append("")

        if recommendation.sensitivitySchedule.count > 1 {
            appendSchedule(
                recommendation.sensitivitySchedule,
                title: "Insulin Sensitivity schedule",
                evidenceName: "samples",
                unit: unit,
                to: &lines
            )
        }
        if recommendation.carbRatioSchedule.count > 1 {
            appendSchedule(
                recommendation.carbRatioSchedule,
                title: "Carb Ratio schedule",
                evidenceName: "meals",
                unit: unit,
                to: &lines
            )
        }

        lines.append("Basal schedule [U/hr] — Rounded = nearest \(String(format: "%.3g", basalIncrement)) U/hr (what Loop accepts)")
        lines.append(pad("Hour", 8) + pad("Pump", 12) + pad("LoopTune", 12) + pad("Rounded", 10) + pad("Days missing", 14) + "Flag")
        lines.append(String(repeating: "-", count: 62))
        for hour in recommendation.basalHours where hour.pumpRate != hour.recommendedRate || !hour.untuned {
            lines.append(basalRow(hour, increment: basalIncrement))
        }
        lines.append(String(repeating: "-", count: 62))
        lines.append(
            pad("Total", 8)
            + pad(fmt(recommendation.pumpDailyBasal), 12)
            + pad(fmt(recommendation.tunedDailyBasal), 12)
            + pad(fmt2(recommendation.roundedDailyBasal(increment: basalIncrement)), 10)
        )
        lines.append("")

        // The schedule exactly as entered on Loop's Basal Rates screen: only
        // the change points, start time + rate.
        let loopEntries = recommendation.loopBasalSchedule(increment: basalIncrement)
        lines.append("Basal Rates — as entered in Loop (\(loopEntries.count) entries)")
        lines.append(String(repeating: "-", count: 30))
        for entry in loopEntries {
            lines.append(pad(entry.timeString, 8) + fmt2(entry.rate) + " U/hr")
        }
        lines.append("")
        lines.append(disclaimer)
        return lines.joined(separator: "\n")
    }

    private static func categoryLine(_ counts: [DeviationCategory: Int]) -> String {
        let parts = DeviationCategory.allCasesOrdered.map { "\($0.rawValue.uppercased()): \(counts[$0] ?? 0)" }
        return "Categorized — " + parts.joined(separator: "  ")
    }

    private static func parameterRow(_ rec: ParameterRecommendation, unit: GlucoseUnit) -> String {
        let change = String(format: "%+.0f%%", rec.percentChange)
        let pump = "\(rec.formatted(rec.pumpValue(in: unit), in: unit)) \(rec.unitLabel(in: unit))"
        let tuned = rec.formatted(rec.recommendedValue(in: unit), in: unit)
        return pad(rec.name, 22) + pad(pump, 14) + pad(tuned, 14) + change + flagSuffix(tier: rec.changeTier, status: rec.guardrailStatus)
    }

    private static func appendSchedule(
        _ entries: [ParameterScheduleRecommendation],
        title: String,
        evidenceName: String,
        unit: GlucoseUnit,
        to lines: inout [String]
    ) {
        let unitLabel = entries.first?.parameter.unitLabel(in: unit) ?? ""
        lines.append("\(title) [\(unitLabel)] using existing Loop time blocks")
        lines.append(pad("Time", 8) + pad("Pump", 14) + pad("LoopTune", 14) + "Data")
        lines.append(String(repeating: "-", count: 54))
        for entry in entries {
            let rec = entry.parameter
            let pump = rec.formatted(rec.pumpValue(in: unit), in: unit)
            let tuned = rec.formatted(rec.recommendedValue(in: unit), in: unit)
            let evidence: String
            if entry.untuned && entry.evidenceCount == 0 {
                evidence = "no data"
            } else if entry.untuned {
                evidence = "\(entry.evidenceCount) \(evidenceName), unchanged"
            } else if entry.daysMissing > 0 {
                evidence = "\(entry.evidenceCount) \(evidenceName), \(entry.daysMissing)d missing"
            } else {
                evidence = "\(entry.evidenceCount) \(evidenceName)"
            }
            lines.append(
                pad(entry.timeString, 8)
                + pad(pump, 14)
                + pad(tuned, 14)
                + evidence
                + flagSuffix(tier: rec.changeTier, status: rec.guardrailStatus)
            )
        }
        lines.append("")
    }

    private static func basalRow(_ hour: BasalHourRecommendation, increment: Double) -> String {
        let label = String(format: "%02d:00", hour.hour)
        let flag = hour.untuned ? "(no data)" : tierFlag(hour.changeTier)
        let missing = hour.daysMissing > 0 ? String(hour.daysMissing) : ""
        return pad(label, 8)
            + pad(fmt(hour.pumpRate), 12)
            + pad(fmt(hour.recommendedRate), 12)
            + pad(fmt2(hour.roundedRate(toIncrement: increment)), 10)
            + pad(missing, 14)
            + flag
    }

    private static func fmt2(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // ISO8601DateFormatter is documented thread-safe for formatting.
    nonisolated(unsafe) private static let dayFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()

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
