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
        lines.append("Days analyzed: \(recommendation.daysAnalyzed)   Evidence: \(evidenceTime(recommendation.totalSamples))   Units: \(unit.shortLabel)")
        lines.append(categoryLine(recommendation.categoryCounts))
        if !recommendation.settingsChanges.isEmpty {
            let dates = recommendation.settingsChanges.map { Self.dayFormatter.string(from: $0) }.joined(separator: ", ")
            lines.append("Settings changed during the window (\(dates)); the analysis restarted from your applied settings at each change.")
        }
        if recommendation.excludedOverrideSamples > 0 {
            lines.append("\(evidenceTime(recommendation.excludedOverrideSamples)) of data during insulin-needs overrides was excluded from tuning.")
        }
        let insufficient = recommendation.insufficientData
        if !insufficient.isEmpty {
            lines.append("⚠ Insufficient data: \(insufficient.description). LoopTune makes no recommendation for these. Each shows your pump value and, where possible, a value interpolated from the nearest blocks with enough data. You choose which to enter.")
        }
        lines.append("")

        lines.append(pad("Parameter", 22) + pad("Pump", 14) + pad("LoopTune", 14) + "Change")
        lines.append(String(repeating: "-", count: 60))
        lines.append(parameterRow(recommendation.sensitivity, schedule: recommendation.sensitivitySchedule, unit: unit))
        lines.append(parameterRow(recommendation.carbRatio, schedule: recommendation.carbRatioSchedule, unit: unit))
        lines.append("")

        if recommendation.sensitivitySchedule.count > 1 || insufficient.sensitivityBlocks > 0 {
            appendSchedule(
                recommendation.sensitivitySchedule,
                title: "Insulin Sensitivity schedule",
                evidenceName: "5-min intervals",
                unit: unit,
                to: &lines
            )
        }
        if recommendation.carbRatioSchedule.count > 1 || insufficient.carbRatioBlocks > 0 {
            appendSchedule(
                recommendation.carbRatioSchedule,
                title: "Carb Ratio schedule",
                evidenceName: "meals",
                unit: unit,
                to: &lines
            )
        }

        lines.append("Basal schedule [U/hr] — LoopTune = unrounded; Rounded = nearest \(String(format: "%.3g", basalIncrement)) U/hr step within the tuning limits (what Loop accepts); Flag = change of the Rounded rate")
        lines.append(pad("Hour", 8) + pad("Pump", 12) + pad("LoopTune", 12) + pad("Rounded", 10) + pad("Days missing", 14) + "Flag")
        lines.append(String(repeating: "-", count: 62))
        for hour in recommendation.basalHours
        where hour.pumpRate != hour.recommendedRate || !hour.untuned || hour.insufficientEvidence != nil {
            lines.append(basalRow(hour, increment: basalIncrement))
        }
        lines.append(String(repeating: "-", count: 62))
        lines.append(
            pad("Total", 8)
            + pad(fmt(recommendation.pumpDailyBasal), 12)
            + pad(fmt(recommendation.tunedDailyBasal), 12)
            + pad(fmtRate(recommendation.roundedDailyBasal(increment: basalIncrement), increment: basalIncrement), 10)
        )
        if insufficient.basalHours > 0 {
            lines.append("Totals use the pump rate for hours with insufficient data.")
        }
        lines.append("")

        // The schedule exactly as entered on Loop's Basal Rates screen: only
        // the change points, start time + rate.
        let loopEntries = recommendation.loopBasalSchedule(increment: basalIncrement)
        lines.append("Basal Rates — as entered in Loop (\(loopEntries.count) entries)")
        lines.append(String(repeating: "-", count: 30))
        if insufficient.basalHours > 0 {
            lines.append("Entries marked ⚠ had insufficient data: the rate is your pump rate, not a recommendation.")
        }
        for entry in loopEntries {
            guard let evidence = entry.insufficientEvidence else {
                lines.append(pad(entry.timeString, 8) + fmtRate(entry.rate, increment: basalIncrement) + " U/hr")
                continue
            }
            // The pump rate is one of the choices, so it keeps its precision.
            let pump = BasalHourRecommendation.formattedPumpRate(entry.rate)
            var line = pad(entry.timeString, 8) + pump + " U/hr  ⚠ insufficient data: pump \(pump)"
            if let interpolated = evidence.interpolated {
                line += " or interpolated \(fmtRate(interpolated, increment: basalIncrement)) U/hr"
                if let status = guardrailFlag(entry.interpolatedGuardrailStatus ?? .ok) {
                    line += " (\(status))"
                }
                line += " from \(evidence.sourceTimes.joined(separator: " and "))"
            } else {
                line += " U/hr only; nothing to interpolate from"
            }
            lines.append(line)
        }
        lines.append("")
        lines.append(disclaimer)
        return lines.joined(separator: "\n")
    }

    private static func categoryLine(_ counts: [DeviationCategory: Int]) -> String {
        let parts = DeviationCategory.allCasesOrdered.map { "\($0.rawValue.uppercased()): \(counts[$0] ?? 0)" }
        return "Categorized 5-min intervals — " + parts.joined(separator: "  ")
    }

    private static func parameterRow(
        _ rec: ParameterRecommendation,
        schedule: [ParameterScheduleRecommendation],
        unit: GlucoseUnit
    ) -> String {
        let pump = "\(rec.formatted(rec.pumpValue(in: unit), in: unit)) \(rec.unitLabel(in: unit))"
        let insufficient = schedule.filter { $0.insufficientEvidence != nil }.count
        if insufficient > 0, insufficient == schedule.count {
            // No block has evidence, so there is no recommendation to average.
            return pad(rec.name, 22) + pad(pump, 14) + pad("—", 14) + "insufficient data; see schedule below"
        }
        let change = String(format: "%+.0f%%", rec.percentChange)
        let tuned = rec.formatted(rec.recommendedValue(in: unit), in: unit)
        var row = pad(rec.name, 22) + pad(pump, 14) + pad(tuned, 14) + change + flagSuffix(tier: rec.changeTier, status: rec.guardrailStatus)
        if insufficient > 0 {
            row += "  (\(insufficient) of \(schedule.count) blocks: insufficient data, pump value used)"
        }
        return row
    }

    /// Evidence counted in five-minute intervals, shown as CGM time: "35 min",
    /// "3 h" or "3 h 5 min". Twelve intervals make an hour; dividing before
    /// multiplying keeps every `Int` count in range.
    public static func evidenceTime(_ fiveMinuteIntervals: Int) -> String {
        let intervals = max(0, fiveMinuteIntervals)
        let hours = intervals / 12
        let remainder = intervals % 12 * 5
        if hours == 0 { return "\(remainder) min" }
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
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
            let evidence = entry.evidenceDescription(evidenceName)
            guard let insufficient = entry.insufficientEvidence else {
                let tuned = rec.formatted(rec.recommendedValue(in: unit), in: unit)
                lines.append(
                    pad(entry.timeString, 8)
                    + pad(pump, 14)
                    + pad(tuned, 14)
                    + evidence
                    + flagSuffix(tier: rec.changeTier, status: rec.guardrailStatus)
                )
                continue
            }
            // The pump value is one of the choices, so it keeps its precision.
            let pumpChoice = rec.formattedPumpValue(in: unit)
            lines.append(pad(entry.timeString, 8) + pad(pumpChoice, 14) + pad("—", 14) + evidence + "  insufficient data")
            if let alternative = insufficient.interpolated {
                let value = alternative.formatted(alternative.recommendedValue(in: unit), in: unit)
                let change = String(format: "%+.0f%%", alternative.percentChange)
                lines.append(
                    pad("", 8) + "Choose: pump \(pumpChoice) or interpolated \(value) (\(change) relative to pump"
                    + flagSuffix(tier: alternative.changeTier, status: alternative.guardrailStatus, separator: ", ")
                    + ")."
                )
            } else {
                lines.append(pad("", 8) + "Pump \(pumpChoice) only.")
            }
            lines.append(pad("", 8) + insufficient.note)
        }
        lines.append("")
    }

    private static func basalRow(_ hour: BasalHourRecommendation, increment: Double) -> String {
        let label = String(format: "%02d:00", hour.hour)
        if let insufficient = hour.insufficientEvidence {
            let missing = hour.daysMissing > 0 ? String(hour.daysMissing) : ""
            var flag = "insufficient data: pump \(BasalHourRecommendation.formattedPumpRate(hour.pumpRate))"
            if let rounded = hour.interpolatedRoundedRate(toIncrement: increment) {
                var details = [String]()
                if hour.pumpRate > 0 {
                    details.append("\(signedPercent((rounded - hour.pumpRate) / hour.pumpRate * 100)) relative to pump")
                }
                let tier = tierFlag(hour.interpolatedChangeTier(increment: increment) ?? .minimal)
                if !tier.isEmpty { details.append(tier) }
                if let status = guardrailFlag(hour.interpolatedGuardrailStatus(increment: increment) ?? .ok) {
                    details.append(status)
                }
                details.append("from \(insufficient.sourceTimes.joined(separator: " and "))")
                flag += " or interpolated \(fmtRate(rounded, increment: increment)) (\(details.joined(separator: ", ")))"
            } else {
                flag += " only; nothing to interpolate from"
            }
            return pad(label, 8)
                + pad(fmt(hour.pumpRate), 12)
                + pad("—", 12)
                + pad("—", 10)
                + pad(missing, 14)
                + flag
        }
        let flag = hour.untuned ? "(no data)" : tierFlag(hour.changeTier(increment: increment))
        let missing = hour.daysMissing > 0 ? String(hour.daysMissing) : ""
        return pad(label, 8)
            + pad(fmt(hour.pumpRate), 12)
            + pad(fmt(hour.recommendedRate), 12)
            + pad(fmtRate(hour.roundedRate(toIncrement: increment), increment: increment), 10)
            + pad(missing, 14)
            + flag
    }

    /// Two decimals, or enough to show every step of a finer increment such
    /// as 0.025 U/hr.
    private static func fmtRate(_ value: Double, increment: Double) -> String {
        let decimals = (2...3).first { places in
            let steps = increment * pow(10, Double(places))
            return abs(steps - steps.rounded()) < 1e-6
        } ?? 4
        return String(format: "%.\(decimals)f", value)
    }

    // ISO8601DateFormatter is documented thread-safe for formatting.
    nonisolated(unsafe) private static let dayFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()

    private static func flagSuffix(tier: ChangeTier, status: LoopGuardrails.Status, separator: String = "  ") -> String {
        var flags: [String] = []
        let tierFlag = tierFlag(tier)
        if !tierFlag.isEmpty { flags.append(tierFlag) }
        if let status = guardrailFlag(status) { flags.append(status) }
        return flags.isEmpty ? "" : separator + flags.joined(separator: ", ")
    }

    private static func guardrailFlag(_ status: LoopGuardrails.Status) -> String? {
        switch status {
        case .ok: return nil
        case .outsideRecommended: return "outside recommended range"
        case .atLimit: return "clamped to Loop limit"
        }
    }

    private static func tierFlag(_ tier: ChangeTier) -> String {
        switch tier {
        case .minimal: return ""
        case .notable: return "△"
        case .large: return "⚠"
        }
    }

    /// A signed whole percent, with sub-half-percent changes shown as 0%.
    private static func signedPercent(_ value: Double) -> String {
        abs(value) < 0.5 ? "0%" : String(format: "%+.0f%%", value)
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
