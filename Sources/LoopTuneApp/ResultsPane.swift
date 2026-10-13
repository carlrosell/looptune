import SwiftUI
import LoopTuneKit

/// Right-hand detail pane. While a run is in flight it shows progress or an
/// error; otherwise it shows the selected run in two tabs.
struct DetailPane: View {
    let model: TuningViewModel
    let displayUnit: GlucoseUnit

    private enum Tab: Hashable { case recommendations, diagnostics }
    @State private var tab: Tab = .recommendations

    var body: some View {
        Group {
            if model.phase == .running {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Fetching and replaying your data…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let run = model.selectedRun {
                VStack(spacing: 0) {
                    VStack(spacing: 6) {
                        Picker("View", selection: $tab) {
                            Text("Recommendations").tag(Tab.recommendations)
                            Text("Data & diagnostics").tag(Tab.diagnostics)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        RunSourceLabel(source: run.source)
                    }
                    .padding(10)

                    Divider()

                    switch tab {
                    case .recommendations:
                        ResultsView(
                            recommendation: run.recommendation,
                            diagnostics: run.diagnostics,
                            displayUnit: displayUnit
                        )
                    case .diagnostics:
                        DiagnosticsView(run: run, displayUnit: displayUnit)
                    }
                }
            } else if case .failed(let message) = model.phase {
                ContentUnavailableView {
                    Label("Couldn't analyze", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            } else {
                ContentUnavailableView {
                    Label("Ready to analyze", systemImage: "waveform.path.ecg")
                } description: {
                    Text("Connect your Nightscout site, then click Analyze.")
                }
            }
        }
    }
}

/// The recommendation display.
struct ResultsView: View {
    let recommendation: TuningRecommendation
    let diagnostics: RunDiagnostics
    let displayUnit: GlucoseUnit
    /// Finder-style multi-selection: click, ⌘-click, ⇧-click — handy for
    /// ticking off rows already entered into Loop.
    @State private var basalSelection = Set<Int>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                verdictHeader

                DisclaimerBanner()

                HStack(spacing: 16) {
                    ParameterCard(
                        rec: recommendation.sensitivity,
                        schedule: recommendation.sensitivitySchedule,
                        displayUnit: displayUnit
                    )
                    ParameterCard(
                        rec: recommendation.carbRatio,
                        schedule: recommendation.carbRatioSchedule,
                        displayUnit: displayUnit
                    )
                }

                if recommendation.sensitivitySchedule.count > 1
                    || recommendation.insufficientData.sensitivityBlocks > 0 {
                    ParameterScheduleCard(
                        title: "Insulin sensitivity by time of day",
                        entries: recommendation.sensitivitySchedule,
                        evidenceName: "5-min intervals",
                        displayUnit: displayUnit
                    )
                }

                if recommendation.carbRatioSchedule.count > 1
                    || recommendation.insufficientData.carbRatioBlocks > 0 {
                    ParameterScheduleCard(
                        title: "Carb ratio by time of day",
                        entries: recommendation.carbRatioSchedule,
                        evidenceName: "meals",
                        displayUnit: displayUnit
                    )
                }

                HourlyGlucoseOutcomeView(
                    diagnostics: diagnostics,
                    displayUnit: displayUnit
                )

                BasalChartView(hours: recommendation.basalHours)
                CoverageChartView(hours: recommendation.basalHours)

                LoopScheduleCard(recommendation: recommendation)

                VStack(alignment: .leading, spacing: 8) {
                    basalTable
                    InsufficientDataNotes(notes: InsufficientDataNotes.notes(for: recommendation.basalHours))
                }
            }
            .padding(24)
        }
        .animation(.default, value: displayUnit)
    }

    /// The takeaway, before any table: what changed, and by how much.
    private var verdictHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested changes")
                .font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                MetricBadge(
                    label: "Basal",
                    percent: basalPercentChange,
                    insufficientData: recommendation.insufficientData.allBasalHours
                )
                MetricBadge(
                    label: "ISF",
                    percent: recommendation.sensitivity.percentChange,
                    insufficientData: recommendation.insufficientData.allSensitivityBlocks
                )
                MetricBadge(
                    label: "Carb ratio",
                    percent: recommendation.carbRatio.percentChange,
                    insufficientData: recommendation.insufficientData.allCarbRatioBlocks
                )
            }
            Text("vs your pump settings · \(recommendation.daysAnalyzed) day\(recommendation.daysAnalyzed == 1 ? "" : "s"), \(TuningReport.evidenceTime(recommendation.totalSamples)) of data")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !recommendation.settingsChanges.isEmpty {
                Label {
                    Text("You changed settings \(recommendation.settingsChanges.count == 1 ? "once" : "\(recommendation.settingsChanges.count) times") during this window — the analysis restarted from your applied settings at each change, so earlier days don't count against your new profile.")
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !recommendation.insufficientData.isEmpty {
                Label {
                    Text("Insufficient data: \(recommendation.insufficientData.description). LoopTune makes no recommendation for these. Each shows your pump value and, where possible, a value interpolated from the nearest blocks with enough data. You choose which to enter.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
            }
            if recommendation.excludedOverrideSamples > 0 {
                Label(
                    "\(TuningReport.evidenceTime(recommendation.excludedOverrideSamples)) of data during insulin-needs overrides was excluded.",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var basalPercentChange: Double {
        guard recommendation.pumpDailyBasal > 0 else { return 0 }
        return (recommendation.roundedDailyBasal() - recommendation.pumpDailyBasal) / recommendation.pumpDailyBasal * 100
    }

    private var basalTable: some View {
        TableCard(
            title: "Basal schedule — hourly detail (U/hr)",
            subtitle: "Enter into Loop = the recommendation rounded to your pump's 0.05 U/hr steps, within the tuning limits.",
            footer: String(
                format: "Daily total: pump %.2f U · LoopTune %.2f U · rounded %.2f U",
                recommendation.pumpDailyBasal,
                recommendation.tunedDailyBasal,
                recommendation.roundedDailyBasal()
            ) + (recommendation.insufficientData.basalHours > 0 ? " · pump rate used for hours with insufficient data" : "")
        ) {
            Table(recommendation.basalHours, selection: $basalSelection) {
                TableColumn("Hour") { hour in
                    Text(String(format: "%02d:00", hour.hour))
                        .monospacedDigit()
                }
                .width(min: 48, ideal: 56)

                TableColumn("Pump") { hour in
                    Text(String(format: "%.3f", hour.pumpRate))
                        .numericCell()
                }
                .width(min: 64, ideal: 76)

                TableColumn("Unrounded") { hour in
                    Text(hour.insufficientEvidence == nil ? String(format: "%.3f", hour.recommendedRate) : "—")
                        .foregroundStyle(.secondary)
                        .numericCell()
                }
                .width(min: 72, ideal: 84)

                TableColumn("Enter into Loop") { hour in
                    if hour.insufficientEvidence != nil {
                        ChoiceText(
                            pump: BasalHourRecommendation.formattedPumpRate(hour.pumpRate),
                            interpolated: hour.interpolatedRoundedRate().map { String(format: "%.2f interpolated", $0) },
                            interpolatedColor: hour.interpolatedChangeTier()?.color ?? .primary,
                            interpolatedStatus: hour.interpolatedGuardrailStatus() ?? .ok
                        )
                        .numericCell()
                    } else {
                        Text(String(format: "%.2f", hour.roundedRate()))
                            .fontWeight(.semibold)
                            .foregroundStyle(hour.changeTier.color)
                            .numericCell()
                    }
                }
                .width(min: 100, ideal: 170)

                TableColumn("Data") { hour in
                    if hour.insufficientEvidence != nil {
                        Text("Insufficient data").foregroundStyle(.orange)
                    } else if hour.untuned {
                        Text("no data").foregroundStyle(.tertiary)
                    } else if hour.daysMissing > 0 {
                        Text("\(hour.daysMissing)d missing").foregroundStyle(.tertiary)
                    } else {
                        Text(TuningReport.evidenceTime(hour.sampleCount)).foregroundStyle(.secondary)
                    }
                }
            }
            .resultsTable(rowCount: recommendation.basalHours.count)
        }
    }

}

/// A tinted capsule showing one parameter's direction and size of change.
/// Symbol + text carry the meaning; the tint is reinforcement, never the only
/// signal.
struct MetricBadge: View {
    let label: String
    let percent: Double
    /// No block had evidence, so there is no change to report (ADR 0011).
    var insufficientData = false

    private var tier: ChangeTier {
        ChangeTier.classify(pump: 100, tuned: 100 + percent)
    }

    private var symbolName: String {
        if insufficientData { return "exclamationmark.triangle.fill" }
        if abs(percent) < 0.5 { return "equal" }
        return percent > 0 ? "arrow.up.right" : "arrow.down.right"
    }

    private var tint: Color {
        switch tier {
        case .minimal: return .gray
        case .notable: return .yellow
        case .large: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .font(.caption2.weight(.bold))
            Text(label)
                .font(.callout)
            Text(insufficientData ? "insufficient data" : formattedSignedPercent(percent))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(background.opacity(0.14), in: Capsule())
    }

    private var foreground: AnyShapeStyle {
        if insufficientData { return AnyShapeStyle(Color.orange) }
        return tier == .minimal ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint)
    }

    private var background: Color {
        insufficientData ? .orange : tint
    }
}

struct ParameterCard: View {
    let rec: ParameterRecommendation
    let schedule: [ParameterScheduleRecommendation]
    let displayUnit: GlucoseUnit

    private var insufficientBlocks: Int {
        schedule.filter { $0.insufficientEvidence != nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rec.name)
                .font(.subheadline.weight(.semibold))
            if insufficientBlocks > 0, insufficientBlocks == schedule.count {
                insufficientContent
            } else {
                recommendationContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    /// No block has evidence, so there is no recommendation to show.
    @ViewBuilder private var insufficientContent: some View {
        Label("Insufficient data", systemImage: "exclamationmark.triangle.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.orange)
        Text("pump \(rec.formatted(rec.pumpValue(in: displayUnit), in: displayUnit)) \(rec.unitLabel(in: displayUnit))  ·  see the schedule below")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var recommendationContent: some View {
        if schedule.count > 1 {
            Text("Daily average")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(rec.formatted(rec.recommendedValue(in: displayUnit), in: displayUnit))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(rec.unitLabel(in: displayUnit))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("was \(rec.formatted(rec.pumpValue(in: displayUnit), in: displayUnit))  ·  \(formattedSignedPercent(rec.percentChange))")
            .font(.caption)
            .foregroundStyle(.secondary)
        if rec.guardrailStatus != .ok {
            Label(
                rec.guardrailStatus == .atLimit ? "Clamped to Loop's limit" : "Outside Loop's recommended range",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption2)
            .foregroundStyle(.orange)
        }
        if insufficientBlocks > 0 {
            Label(
                "\(insufficientBlocks) of \(schedule.count) blocks: insufficient data, pump value used",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption2)
            .foregroundStyle(.orange)
        }
    }
}

/// Format sub-half-percent movement as 0% rather than the confusing -0%.
func formattedSignedPercent(_ value: Double) -> String {
    abs(value) < 0.5 ? "0%" : String(format: "%+.0f%%", value)
}

struct DisclaimerBanner: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text("Experimental analysis, not medical advice. Review every suggestion with your care team, change one setting at a time, and monitor closely.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.orange.opacity(0.35), lineWidth: 1)
        )
    }
}
