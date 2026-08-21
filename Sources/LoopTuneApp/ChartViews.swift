import SwiftUI
import Charts
import LoopTuneKit

/// Chart series colors — a two-slot categorical palette validated (light and
/// dark) with the dataviz six-checks validator. Light-mode aqua sits below 3:1
/// contrast, which is acceptable here because the numeric basal table directly
/// below the chart provides the required relief.
enum ChartPalette {
    static func tuned(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255)
                        : Color(red: 0x2A / 255, green: 0x78 / 255, blue: 0xD6 / 255)
    }

    static func pump(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0x19 / 255, green: 0x9E / 255, blue: 0x70 / 255)
                        : Color(red: 0x1B / 255, green: 0xAF / 255, blue: 0x7A / 255)
    }

    /// "Current settings" series in the diagnostics before/after chart.
    /// Orange↔blue is a high-contrast, CVD-safe pair (validated both modes).
    static func current(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0xD9 / 255, green: 0x59 / 255, blue: 0x26 / 255)
                        : Color(red: 0xEB / 255, green: 0x68 / 255, blue: 0x34 / 255)
    }
}

/// Shared hover-tooltip card: material background, one row per series with a
/// color chip so identity never relies on position alone.
struct ChartTooltip<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
            content()
        }
        .font(.caption)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}

/// One tooltip row: color chip + label + value.
struct TooltipRow: View {
    var color: Color?
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            if let color {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
    }
}

/// The hourly outcome graph shown with a recommendation. Older saved runs
/// predate the compact percentile summaries and need to be reanalyzed.
struct HourlyGlucoseOutcomeView: View {
    let diagnostics: RunDiagnostics
    let displayUnit: GlucoseUnit

    var body: some View {
        if let glucose = diagnostics.hourlyGlucose,
           !glucose.isEmpty {
            HourlyGlucoseChartView(
                distributions: glucose,
                days: diagnostics.daySummaries.count,
                displayUnit: displayUnit
            )
        } else {
            Label {
                Text("Run Analyze again to add the hourly glucose graph to this older result.")
            } icon: {
                Image(systemName: "chart.xyaxis.line")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct DisplayDistribution: Identifiable {
    let hour: Int
    let sampleCount: Int
    let p10: Double
    let p25: Double
    let median: Double
    let p75: Double
    let p90: Double

    var id: Int { hour }

    init(_ source: HourlyValueDistribution, unit: GlucoseUnit) {
        hour = source.hour
        sampleCount = source.sampleCount
        p10 = unit.fromMilligramsPerDeciliter(source.p10)
        p25 = unit.fromMilligramsPerDeciliter(source.p25)
        median = unit.fromMilligramsPerDeciliter(source.median)
        p75 = unit.fromMilligramsPerDeciliter(source.p75)
        p90 = unit.fromMilligramsPerDeciliter(source.p90)
    }
}

private struct CompactChartLegendItem: View {
    let color: Color
    let label: String
    var isBand = false

    var body: some View {
        HStack(spacing: 5) {
            if isBand {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 14, height: 8)
            } else {
                Capsule()
                    .fill(color)
                    .frame(width: 14, height: 2)
            }
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Actual CGM percentile bands by local clock hour, matching the hourly value
/// profiles commonly used by Nightscout analysis tools.
struct HourlyGlucoseChartView: View {
    let distributions: [HourlyValueDistribution]
    let days: Int
    let displayUnit: GlucoseUnit
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedHour: Int?

    private var rows: [DisplayDistribution] {
        distributions.map { DisplayDistribution($0, unit: displayUnit) }
    }

    private var hovered: DisplayDistribution? {
        guard let selectedHour else { return nil }
        let clamped = min(max(selectedHour, 0), 23)
        return rows.first { $0.hour == clamped }
    }

    private var referenceLow: Double {
        displayUnit.fromMilligramsPerDeciliter(70)
    }

    private var referenceHigh: Double {
        displayUnit.fromMilligramsPerDeciliter(180)
    }

    private var yDomain: ClosedRange<Double> {
        let lowest = min(referenceLow, rows.map(\.p10).min() ?? referenceLow)
        let highest = max(referenceHigh, rows.map(\.p90).max() ?? referenceHigh)
        let padding = max((highest - lowest) * 0.08, displayUnit == .millimolesPerLiter ? 0.3 : 5)
        return max(0, lowest - padding)...(highest + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your glucose by hour")
                .font(.headline)
            Text("What actually happened during \(days) analyzed day\(days == 1 ? "" : "s"), grouped by local clock hour.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                CompactChartLegendItem(color: .primary, label: "Median")
                CompactChartLegendItem(
                    color: ChartPalette.tuned(colorScheme).opacity(0.22),
                    label: "25–75%",
                    isBand: true
                )
                CompactChartLegendItem(
                    color: ChartPalette.tuned(colorScheme).opacity(0.10),
                    label: "10–90%",
                    isBand: true
                )
            }
            Chart {
                ForEach(rows) { row in
                    AreaMark(
                        x: .value("Hour", row.hour),
                        yStart: .value("10th percentile", row.p10),
                        yEnd: .value("90th percentile", row.p90)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(by: .value("Series", "10–90%"))
                }
                ForEach(rows) { row in
                    AreaMark(
                        x: .value("Hour", row.hour),
                        yStart: .value("25th percentile", row.p25),
                        yEnd: .value("75th percentile", row.p75)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(by: .value("Series", "25–75%"))
                }
                ForEach(rows) { row in
                    LineMark(
                        x: .value("Hour", row.hour),
                        y: .value("Median glucose", row.median)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(by: .value("Series", "Median"))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                RuleMark(y: .value("Upper reference", referenceHigh))
                    .foregroundStyle(.orange.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                RuleMark(y: .value("Lower reference", referenceLow))
                    .foregroundStyle(.red.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                if let hovered {
                    RuleMark(x: .value("Hour", hovered.hour))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(
                            position: .top,
                            spacing: 4,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            ChartTooltip(title: hourRange(hovered.hour)) {
                                TooltipRow(color: .primary, label: "Median", value: glucoseValue(hovered.median))
                                TooltipRow(color: nil, label: "25–75%", value: glucoseRange(hovered.p25, hovered.p75))
                                TooltipRow(color: nil, label: "10–90%", value: glucoseRange(hovered.p10, hovered.p90))
                                TooltipRow(color: nil, label: "Readings", value: "\(hovered.sampleCount)")
                            }
                        }
                }
            }
            .chartForegroundStyleScale([
                "10–90%": ChartPalette.tuned(colorScheme).opacity(0.10),
                "25–75%": ChartPalette.tuned(colorScheme).opacity(0.22),
                "Median": Color.primary,
            ])
            .chartLegend(.hidden)
            .chartXSelection(value: $selectedHour)
            .chartXScale(domain: 0...23)
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: [0, 4, 8, 12, 16, 20, 23]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text(String(format: "%02d:00", hour))
                        }
                    }
                }
            }
            .chartYAxisLabel(displayUnit.shortLabel, position: .trailing)
            .frame(height: 240)
            Text("Reference lines: \(glucoseValue(referenceLow)) low · \(glucoseValue(referenceHigh)) high. These are the app's \(glucoseRange(referenceLow, referenceHigh)) \(displayUnit.shortLabel) reporting range, not a personalized target.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func hourRange(_ hour: Int) -> String {
        String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24)
    }

    private func glucoseValue(_ value: Double) -> String {
        let format = displayUnit == .millimolesPerLiter ? "%.1f %@" : "%.0f %@"
        return String(format: format, value, displayUnit.shortLabel)
    }

    private func glucoseRange(_ low: Double, _ high: Double) -> String {
        let format = displayUnit == .millimolesPerLiter ? "%.1f–%.1f" : "%.0f–%.0f"
        return String(format: format, low, high)
    }
}

/// 24-hour basal schedule: pump vs LoopTune as step lines.
struct BasalChartView: View {
    let hours: [BasalHourRecommendation]
    @Environment(\.colorScheme) private var colorScheme
    /// Hovered x position (macOS pointer tracking via chartXSelection).
    @State private var selectedHour: Int?

    private var hoveredHour: BasalHourRecommendation? {
        guard let selectedHour else { return nil }
        let clamped = min(max(selectedHour, 0), 23)
        return hours.first { $0.hour == clamped }
    }

    private struct Point: Identifiable {
        let id: String
        let hour: Int
        let rate: Double
        let series: String
    }

    /// Step-line points; hour 24 repeats the last value so the final step has
    /// visible width.
    private var points: [Point] {
        var result: [Point] = []
        for entry in hours {
            result.append(Point(id: "p\(entry.hour)", hour: entry.hour, rate: entry.pumpRate, series: "Pump"))
            result.append(Point(id: "t\(entry.hour)", hour: entry.hour, rate: entry.recommendedRate, series: "LoopTune"))
        }
        if let last = hours.last {
            result.append(Point(id: "p24", hour: 24, rate: last.pumpRate, series: "Pump"))
            result.append(Point(id: "t24", hour: 24, rate: last.recommendedRate, series: "LoopTune"))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Basal schedule — pump vs LoopTune (U/hr)")
                .font(.subheadline.weight(.semibold))
            Text("A mismatch observed in one hour tunes the previous three basal hours, because the insulin delivered there acts later.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Hour", point.hour),
                        y: .value("U/hr", point.rate)
                    )
                    .foregroundStyle(by: .value("Series", point.series))
                    .interpolationMethod(.stepEnd)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let hovered = hoveredHour {
                    RuleMark(x: .value("Hour", hovered.hour))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(
                            position: .top,
                            spacing: 4,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            ChartTooltip(title: String(format: "%02d:00–%02d:00", hovered.hour, (hovered.hour + 1) % 24)) {
                                TooltipRow(color: ChartPalette.pump(colorScheme), label: "Pump", value: String(format: "%.3f U/hr", hovered.pumpRate))
                                TooltipRow(color: ChartPalette.tuned(colorScheme), label: "LoopTune", value: String(format: "%.3f U/hr", hovered.recommendedRate))
                                TooltipRow(color: nil, label: "Enter into Loop", value: String(format: "%.2f U/hr", hovered.roundedRate()))
                            }
                        }
                }
            }
            .chartForegroundStyleScale([
                "LoopTune": ChartPalette.tuned(colorScheme),
                "Pump": ChartPalette.pump(colorScheme),
            ])
            .chartXSelection(value: $selectedHour)
            .chartXScale(domain: 0...24)
            .chartXAxis {
                AxisMarks(values: [0, 4, 8, 12, 16, 20, 24]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text(String(format: "%02d:00", hour % 24))
                        }
                    }
                }
            }
            .chartYAxisLabel("U/hr", position: .trailing)
            .frame(height: 180)
        }
    }
}

/// Per-hour basal data coverage: how many deviation samples informed each
/// scheduled basal hour after the tuner's three-hour lookback.
/// Hours with no direct evidence appear as gaps (and are flagged in the table).
struct CoverageChartView: View {
    let hours: [BasalHourRecommendation]
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedHour: Int?

    private var hoveredHour: BasalHourRecommendation? {
        guard let selectedHour else { return nil }
        let clamped = min(max(selectedHour, 0), 23)
        return hours.first { $0.hour == clamped }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Data coverage — samples informing each basal hour")
                .font(.subheadline.weight(.semibold))
            Chart {
                ForEach(hours, id: \.hour) { entry in
                    BarMark(
                        x: .value("Hour", entry.hour),
                        y: .value("Samples", entry.sampleCount),
                        width: .fixed(8)
                    )
                    .foregroundStyle(ChartPalette.tuned(colorScheme))
                    .cornerRadius(2)
                }
                if let hovered = hoveredHour {
                    RuleMark(x: .value("Hour", hovered.hour))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(
                            position: .top,
                            spacing: 4,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            ChartTooltip(title: String(format: "%02d:00", hovered.hour)) {
                                TooltipRow(
                                    color: ChartPalette.tuned(colorScheme),
                                    label: "Samples",
                                    value: hovered.sampleCount > 0 ? "\(hovered.sampleCount)" : "no data"
                                )
                                if hovered.daysMissing > 0 {
                                    TooltipRow(color: nil, label: "Days missing", value: "\(hovered.daysMissing)")
                                }
                            }
                        }
                }
            }
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
            .frame(height: 90)
            if hours.contains(where: { $0.sampleCount == 0 }) {
                Text("Hours without bars had no direct basal evidence; their recommendations are interpolated from neighboring hours.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
