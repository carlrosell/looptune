import SwiftUI
import Charts
import LoopTuneKit

/// The "Data & diagnostics" tab: what was ingested, what the algorithm thinks
/// is off under the settings recorded at the time, and how the recommendation
/// would change the historical replay.
struct DiagnosticsView: View {
    let run: SavedRun
    let displayUnit: GlucoseUnit
    @Environment(\.colorScheme) private var colorScheme
    @State private var daySelection = Set<String>()
    @State private var selectedHour: Int?

    private var diagnostics: RunDiagnostics { run.diagnostics }

    private var hoveredDeviation: HourDeviation? {
        guard let selectedHour else { return nil }
        let clamped = min(max(selectedHour, 0), 23)
        return diagnostics.hourlyDeviation.first { $0.hour == clamped }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DisclaimerBanner()
                improvementCard
                problemSummary
                deviationChart
                deviationTable
                ingestedDataTable
            }
            .padding(24)
        }
    }

    // MARK: - Headline

    private var improvementCard: some View {
        let improvement = diagnostics.improvementPercent
        return VStack(alignment: .leading, spacing: 8) {
            Text("Historical replay fit")
                .font(.title2.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                statBlock(
                    title: "Recorded",
                    value: deviationNumber(diagnostics.meanAbsDeviationBefore),
                    unit: "\(displayUnit.shortLabel) / 5 min",
                    tint: ChartPalette.current(colorScheme)
                )
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                statBlock(
                    title: "Recommended",
                    value: deviationNumber(diagnostics.meanAbsDeviationAfter),
                    unit: "\(displayUnit.shortLabel) / 5 min",
                    tint: ChartPalette.tuned(colorScheme)
                )
                Spacer()
            }
            Text(improvementText(improvement))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func statBlock(title: String, value: String, unit: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func improvementText(_ improvement: Double) -> String {
        if improvement >= 1 {
            return String(
                format: "On this same historical window, the recommendation's average replay residual is %.0f%% lower. This in-sample fit does not show that future glucose will improve.",
                improvement
            )
        } else if improvement <= -1 {
            return String(
                format: "Warning: the recommendation fits this historical replay %.0f%% worse than the recorded settings. Do not treat this diagnostic as support for the change.",
                abs(improvement)
            )
        } else {
            return "The recorded settings and the recommendation fit the historical data about equally over this window."
        }
    }

    // MARK: - What's wrong

    @ViewBuilder
    private var problemSummary: some View {
        let problems = diagnostics.problemHours
        if problems.isEmpty {
            Label("No hour is running consistently high or low under the settings recorded at the time.", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("What's running off", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                ForEach(problems) { hour in
                    Text(problemLine(hour))
                        .font(.callout)
                }
            }
        }
    }

    private func problemLine(_ hour: HourDeviation) -> String {
        let direction = hour.before > 0 ? "running high" : "running low"
        let time = String(format: "%02d:00", hour.hour)
        if hour.improves {
            return "• \(time): \(direction) (avg \(deviationNumber(hour.before, signed: true)) \(displayUnit.shortLabel) per reading). In the historical replay, the recommendation brings this to \(deviationNumber(hour.after, signed: true)) \(displayUnit.shortLabel)."
        }
        return "• \(time): \(direction) (avg \(deviationNumber(hour.before, signed: true)) \(displayUnit.shortLabel) per reading)."
    }

    // MARK: - Deviation chart

    private var deviationChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Average glucose deviation by hour")
                .font(.subheadline.weight(.semibold))
            Text("Distance between what happened and what the settings predict. Zero is a perfect fit; above zero ran high, below ran low.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart {
                ForEach(diagnostics.hourlyDeviation) { hour in
                    BarMark(
                        x: .value("Hour", hour.hour),
                        y: .value("Deviation", displayUnit.fromMilligramsPerDeciliter(hour.before)),
                        width: .fixed(6)
                    )
                    .position(by: .value("Series", "Recorded"))
                    .foregroundStyle(by: .value("Series", "Recorded"))
                }
                ForEach(diagnostics.hourlyDeviation) { hour in
                    BarMark(
                        x: .value("Hour", hour.hour),
                        y: .value("Deviation", displayUnit.fromMilligramsPerDeciliter(hour.after)),
                        width: .fixed(6)
                    )
                    .position(by: .value("Series", "Recommended"))
                    .foregroundStyle(by: .value("Series", "Recommended"))
                }
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                if let hovered = hoveredDeviation {
                    RuleMark(x: .value("Hour", hovered.hour))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(
                            position: .top,
                            spacing: 4,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            ChartTooltip(title: String(format: "%02d:00", hovered.hour)) {
                                if hovered.sampleCount == 0 {
                                    TooltipRow(color: nil, label: "No data", value: "")
                                } else {
                                    TooltipRow(
                                        color: ChartPalette.current(colorScheme),
                                        label: "Recorded",
                                        value: "\(deviationNumber(hovered.before, signed: true)) \(displayUnit.shortLabel)"
                                    )
                                    TooltipRow(
                                        color: ChartPalette.tuned(colorScheme),
                                        label: "Recommended",
                                        value: "\(deviationNumber(hovered.after, signed: true)) \(displayUnit.shortLabel)"
                                    )
                                    TooltipRow(color: nil, label: "Samples", value: "\(hovered.sampleCount)")
                                }
                            }
                        }
                }
            }
            .chartForegroundStyleScale([
                "Recorded": ChartPalette.current(colorScheme),
                "Recommended": ChartPalette.tuned(colorScheme),
            ])
            .chartXSelection(value: $selectedHour)
            .chartXScale(domain: -1...24)
            .chartXAxis {
                AxisMarks(values: [0, 4, 8, 12, 16, 20, 23]) { value in
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text(String(format: "%02d", hour))
                        }
                    }
                }
            }
            .chartYAxisLabel(displayUnit.shortLabel, position: .trailing)
            .frame(height: 200)
        }
    }

    // MARK: - Deviation table

    private var deviationTable: some View {
        TableCard(
            title: "Deviation by hour (\(displayUnit.shortLabel))",
            subtitle: "Recorded = settings active at the time · Recommended = suggested settings replayed over the same history."
        ) {
            Table(diagnostics.hourlyDeviation) {
                TableColumn("Hour") { hour in
                    Text(String(format: "%02d:00", hour.hour)).monospacedDigit()
                }
                .width(min: 48, ideal: 56)

                TableColumn("Recorded") { hour in
                    Text(deviationNumber(hour.before, signed: true))
                        .foregroundStyle(hour.isProblem ? AnyShapeStyle(ChartPalette.current(colorScheme)) : AnyShapeStyle(.primary))
                        .numericCell()
                }
                .width(min: 64, ideal: 76)

                TableColumn("Recommended") { hour in
                    Text(deviationNumber(hour.after, signed: true)).numericCell()
                }
                .width(min: 84, ideal: 96)

                TableColumn("Status") { hour in
                    if hour.sampleCount == 0 {
                        Text("no data").foregroundStyle(.tertiary)
                    } else if hour.isProblem && hour.improves {
                        Label("improved", systemImage: "arrow.down.circle").foregroundStyle(ChartPalette.tuned(colorScheme))
                    } else if hour.isProblem {
                        Label("flagged", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        Text("ok").foregroundStyle(.secondary)
                    }
                }
            }
            .resultsTable(rowCount: diagnostics.hourlyDeviation.count)
        }
    }

    // MARK: - Ingested data

    private var ingestedDataTable: some View {
        TableCard(
            title: "Ingested data by day",
            subtitle: "\(diagnostics.glucoseCount) CGM readings · \(diagnostics.doseCount) doses · \(diagnostics.carbCount) carb entries"
        ) {
            Table(diagnostics.daySummaries, selection: $daySelection) {
                TableColumn("Day") { day in
                    Text(day.date).monospacedDigit()
                }
                .width(min: 90, ideal: 100)

                TableColumn("CGM") { day in
                    Text("\(day.glucoseCount)").numericCell()
                }
                .width(min: 48, ideal: 56)

                TableColumn("Mean \(displayUnit.shortLabel)") { day in
                    Text(glucoseNumber(day.meanGlucose)).numericCell()
                }
                .width(min: 48, ideal: 56)

                TableColumn("In range") { day in
                    Text(String(format: "%.0f%%", day.timeInRangePercent)).numericCell()
                }
                .width(min: 64, ideal: 72)

                TableColumn("Boluses") { day in
                    Text("\(day.bolusCount)").foregroundStyle(.secondary).numericCell()
                }
                .width(min: 60, ideal: 68)

                TableColumn("Bolus U") { day in
                    Text(String(format: "%.1f U", day.totalBolusInsulin)).numericCell()
                }
                .width(min: 64, ideal: 74)

                TableColumn("Carbs") { day in
                    Text(day.carbCount > 0 ? String(format: "%.0f g", day.totalCarbs) : "—")
                        .foregroundStyle(.secondary).numericCell()
                }
                .width(min: 56, ideal: 66)
            }
            .resultsTable(rowCount: diagnostics.daySummaries.count)
        }
    }

    private func deviationNumber(_ milligramsPerDeciliter: Double, signed: Bool = false) -> String {
        let value = displayUnit.fromMilligramsPerDeciliter(milligramsPerDeciliter)
        switch (displayUnit, signed) {
        case (.milligramsPerDeciliter, false):
            return String(format: "%.1f", value)
        case (.milligramsPerDeciliter, true):
            return String(format: "%+.1f", value)
        case (.millimolesPerLiter, false):
            return String(format: "%.2f", value)
        case (.millimolesPerLiter, true):
            return String(format: "%+.2f", value)
        }
    }

    private func glucoseNumber(_ milligramsPerDeciliter: Double) -> String {
        let value = displayUnit.fromMilligramsPerDeciliter(milligramsPerDeciliter)
        return displayUnit == .millimolesPerLiter
            ? String(format: "%.1f", value)
            : String(format: "%.0f", value)
    }
}
