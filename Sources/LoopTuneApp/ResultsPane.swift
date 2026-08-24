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
                    Picker("View", selection: $tab) {
                        Text("Recommendations").tag(Tab.recommendations)
                        Text("Data & diagnostics").tag(Tab.diagnostics)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
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
                        displayUnit: displayUnit,
                        isDailyAverage: recommendation.sensitivitySchedule.count > 1
                    )
                    ParameterCard(
                        rec: recommendation.carbRatio,
                        displayUnit: displayUnit,
                        isDailyAverage: recommendation.carbRatioSchedule.count > 1
                    )
                }

                if recommendation.sensitivitySchedule.count > 1 {
                    ParameterScheduleCard(
                        title: "Insulin sensitivity by time of day",
                        entries: recommendation.sensitivitySchedule,
                        evidenceName: "samples",
                        displayUnit: displayUnit
                    )
                }

                if recommendation.carbRatioSchedule.count > 1 {
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

                basalTable
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
                MetricBadge(label: "Basal", percent: basalPercentChange)
                MetricBadge(label: "ISF", percent: recommendation.sensitivity.percentChange)
                MetricBadge(label: "Carb ratio", percent: recommendation.carbRatio.percentChange)
            }
            Text("vs your pump settings · \(recommendation.daysAnalyzed) day\(recommendation.daysAnalyzed == 1 ? "" : "s"), \(recommendation.totalSamples) samples")
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
            if recommendation.excludedOverrideSamples > 0 {
                Label(
                    "\(recommendation.excludedOverrideSamples) samples during insulin-needs overrides were excluded.",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var basalPercentChange: Double {
        guard recommendation.pumpDailyBasal > 0 else { return 0 }
        return (recommendation.tunedDailyBasal - recommendation.pumpDailyBasal) / recommendation.pumpDailyBasal * 100
    }

    private var basalTable: some View {
        TableCard(
            title: "Basal schedule — hourly detail (U/hr)",
            subtitle: "Enter into Loop = the raw recommendation rounded to your pump's 0.05 U/hr steps.",
            footer: String(
                format: "Daily total: pump %.2f U · LoopTune %.2f U · rounded %.2f U",
                recommendation.pumpDailyBasal,
                recommendation.tunedDailyBasal,
                recommendation.roundedDailyBasal()
            )
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

                TableColumn("LoopTune") { hour in
                    Text(String(format: "%.3f", hour.recommendedRate))
                        .foregroundStyle(.secondary)
                        .numericCell()
                }
                .width(min: 72, ideal: 84)

                TableColumn("Enter into Loop") { hour in
                    Text(String(format: "%.2f", hour.roundedRate()))
                        .fontWeight(.semibold)
                        .foregroundStyle(color(for: hour.changeTier))
                        .numericCell()
                }
                .width(min: 100, ideal: 112)

                TableColumn("Data") { hour in
                    if hour.untuned {
                        Text("no data").foregroundStyle(.tertiary)
                    } else if hour.daysMissing > 0 {
                        Text("\(hour.daysMissing)d missing").foregroundStyle(.tertiary)
                    } else {
                        Text("\(hour.sampleCount) samples").foregroundStyle(.secondary)
                    }
                }
            }
            .resultsTable(rowCount: recommendation.basalHours.count)
        }
    }

    private func color(for tier: ChangeTier) -> Color {
        switch tier {
        case .minimal: return .primary
        case .notable: return .yellow
        case .large: return .orange
        }
    }
}

/// A tinted capsule showing one parameter's direction and size of change.
/// Symbol + text carry the meaning; the tint is reinforcement, never the only
/// signal.
struct MetricBadge: View {
    let label: String
    let percent: Double

    private var tier: ChangeTier {
        ChangeTier.classify(pump: 100, tuned: 100 + percent)
    }

    private var symbolName: String {
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
            Text(formattedSignedPercent(percent))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .foregroundStyle(tier == .minimal ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

struct ParameterCard: View {
    let rec: ParameterRecommendation
    let displayUnit: GlucoseUnit
    var isDailyAverage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rec.name)
                .font(.subheadline.weight(.semibold))
            if isDailyAverage {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
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
