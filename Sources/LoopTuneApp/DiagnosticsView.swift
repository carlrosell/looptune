import SwiftUI
import Charts
import LoopTuneKit

/// The "Data & diagnostics" tab: what was ingested, what the algorithm thinks
/// is off under current settings, and how the recommendation would change it.
struct DiagnosticsView: View {
    let run: SavedRun
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
            Text("How well the settings explain your glucose")
                .font(.title2.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                statBlock(
                    title: "Now",
                    value: String(format: "%.1f", diagnostics.meanAbsDeviationBefore),
                    unit: "mg/dL",
                    tint: ChartPalette.current(colorScheme)
                )
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                statBlock(
                    title: "Recommended",
                    value: String(format: "%.1f", diagnostics.meanAbsDeviationAfter),
                    unit: "mg/dL",
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
            return String(format: "The recommended settings explain your glucose about %.0f%% more accurately (lower average deviation between what happened and what the model predicted).", improvement)
        } else if improvement <= -1 {
            return "Your current settings already explain the data well over this window — the recommendation barely changes the fit."
        } else {
            return "Your current settings and the recommendation fit the data about equally over this window."
        }
    }

    // MARK: - What's wrong

    @ViewBuilder
    private var problemSummary: some View {
        let problems = diagnostics.problemHours
        if problems.isEmpty {
            Label("No hour is running consistently high or low under your current settings.", systemImage: "checkmark.circle")
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
            return "• \(time): \(direction) (avg \(signed(hour.before)) mg/dL per reading). Recommended settings bring this to \(signed(hour.after))."
        }
        return "• \(time): \(direction) (avg \(signed(hour.before)) mg/dL per reading)."
    }

    private func signed(_ value: Double) -> String { String(format: "%+.1f", value) }

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
                        y: .value("Deviation", hour.before),
                        width: .fixed(6)
                    )
                    .position(by: .value("Series", "Now"))
                    .foregroundStyle(by: .value("Series", "Now"))
                }
                ForEach(diagnostics.hourlyDeviation) { hour in
                    BarMark(
                        x: .value("Hour", hour.hour),
                        y: .value("Deviation", hour.after),
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
                                    TooltipRow(color: ChartPalette.current(colorScheme), label: "Now", value: String(format: "%+.1f mg/dL", hovered.before))
                                    TooltipRow(color: ChartPalette.tuned(colorScheme), label: "Recommended", value: String(format: "%+.1f mg/dL", hovered.after))
                                    TooltipRow(color: nil, label: "Samples", value: "\(hovered.sampleCount)")
                                }
                            }
                        }
                }
            }
            .chartForegroundStyleScale([
                "Now": ChartPalette.current(colorScheme),
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
            .chartYAxisLabel("mg/dL", position: .trailing)
            .frame(height: 200)
        }
    }

    // MARK: - Deviation table

    private var deviationTable: some View {
        TableCard(
            title: "Deviation by hour (mg/dL)",
            subtitle: "Now = your current settings · Recommended = the suggested settings."
        ) {
            Table(diagnostics.hourlyDeviation) {
                TableColumn("Hour") { hour in
                    Text(String(format: "%02d:00", hour.hour)).monospacedDigit()
                }
                .width(min: 48, ideal: 56)

                TableColumn("Now") { hour in
                    Text(signed(hour.before))
                        .foregroundStyle(hour.isProblem ? AnyShapeStyle(ChartPalette.current(colorScheme)) : AnyShapeStyle(.primary))
                        .numericCell()
                }
                .width(min: 64, ideal: 76)

                TableColumn("Recommended") { hour in
                    Text(signed(hour.after)).numericCell()
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

                TableColumn("Mean") { day in
                    Text(String(format: "%.0f", day.meanGlucose)).numericCell()
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

                TableColumn("Insulin") { day in
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
}
