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
    let segment: Int
    let sampleCount: Int
    let p10: Double
    let p25: Double
    let median: Double
    let p75: Double
    let p90: Double

    var id: Int { hour }

    init(_ source: HourlyValueDistribution, unit: GlucoseUnit, segment: Int) {
        hour = source.hour
        self.segment = segment
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
        var segment = 0
        var previousHour: Int?
        return distributions.map { distribution in
            if let previousHour, distribution.hour != previousHour + 1 {
                segment += 1
            }
            previousHour = distribution.hour
            return DisplayDistribution(distribution, unit: displayUnit, segment: segment)
        }
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
                        yEnd: .value("90th percentile", row.p90),
                        series: .value("Segment", "10–90%-\(row.segment)")
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(by: .value("Series", "10–90%"))
                    RectangleMark(
                        x: .value("Hour", row.hour),
                        yStart: .value("10th percentile", row.p10),
                        yEnd: .value("90th percentile", row.p90),
                        width: .fixed(4)
                    )
                    .foregroundStyle(by: .value("Series", "10–90%"))
                }
                ForEach(rows) { row in
                    AreaMark(
                        x: .value("Hour", row.hour),
                        yStart: .value("25th percentile", row.p25),
                        yEnd: .value("75th percentile", row.p75),
                        series: .value("Segment", "25–75%-\(row.segment)")
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(by: .value("Series", "25–75%"))
                    RectangleMark(
                        x: .value("Hour", row.hour),
                        yStart: .value("25th percentile", row.p25),
                        yEnd: .value("75th percentile", row.p75),
                        width: .fixed(4)
                    )
                    .foregroundStyle(by: .value("Series", "25–75%"))
                }
                ForEach(rows) { row in
                    LineMark(
                        x: .value("Hour", row.hour),
                        y: .value("Median glucose", row.median),
                        series: .value("Segment", "Median-\(row.segment)")
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(by: .value("Series", "Median"))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(
                        x: .value("Hour", row.hour),
                        y: .value("Median glucose", row.median)
                    )
                    .foregroundStyle(by: .value("Series", "Median"))
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
                                TooltipRow(color: nil, label: "25–75%", value: "\(glucoseRange(hovered.p25, hovered.p75)) \(displayUnit.shortLabel)")
                                TooltipRow(color: nil, label: "10–90%", value: "\(glucoseRange(hovered.p10, hovered.p90)) \(displayUnit.shortLabel)")
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

/// The basal chart's series and tooltip text, kept apart from the view so
/// the presentation of hours with insufficient data can be tested.
enum BasalChartData {
    enum Series: String {
        case pump = "Pump"
        case loopTune = "LoopTune"
        /// The alternative for hours with insufficient data (ADR 0011). It is
        /// not LoopTune's recommendation.
        case interpolated = "Interpolated (insufficient data)"
    }

    struct Point: Identifiable, Equatable {
        var id: String { "\(segment)-\(hour)" }
        let hour: Int
        let rate: Double
        let series: Series
        /// One unbroken line. The LoopTune and interpolated series break
        /// wherever the hours change kind.
        let segment: String
    }

    struct TooltipLine: Equatable {
        let series: Series?
        let label: String
        let value: String
    }

    /// Step-line points. Each segment repeats its last value one hour later
    /// so its final step has visible width. Hours with insufficient data have
    /// no LoopTune point: their recommended rate is only the pump rate.
    static func points(for hours: [BasalHourRecommendation]) -> [Point] {
        let sorted = hours.sorted { $0.hour < $1.hour }
        var result = sorted.map { Point(hour: $0.hour, rate: $0.pumpRate, series: .pump, segment: "Pump") }
        if let last = sorted.last {
            result.append(Point(hour: last.hour + 1, rate: last.pumpRate, series: .pump, segment: "Pump"))
        }
        var segment = 0
        var previous: (hour: Int, series: Series, rate: Double)?
        for entry in sorted {
            let current = value(of: entry)
            if let open = previous, current?.series != open.series || entry.hour != open.hour + 1 {
                result.append(Point(hour: open.hour + 1, rate: open.rate, series: open.series, segment: "\(open.series.rawValue)-\(segment)"))
                segment += 1
                previous = nil
            }
            guard let current else { continue }
            result.append(Point(hour: entry.hour, rate: current.rate, series: current.series, segment: "\(current.series.rawValue)-\(segment)"))
            previous = (entry.hour, current.series, current.rate)
        }
        if let open = previous {
            result.append(Point(hour: open.hour + 1, rate: open.rate, series: open.series, segment: "\(open.series.rawValue)-\(segment)"))
        }
        return result
    }

    private static func value(of hour: BasalHourRecommendation) -> (series: Series, rate: Double)? {
        guard let evidence = hour.insufficientEvidence else { return (.loopTune, hour.recommendedRate) }
        return evidence.interpolated.map { (.interpolated, $0) }
    }

    /// Runs of consecutive hours with insufficient data, as `start..<end`.
    static func insufficientRanges(for hours: [BasalHourRecommendation]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for hour in hours.sorted(by: { $0.hour < $1.hour }) where hour.insufficientEvidence != nil {
            if let last = ranges.last, last.upperBound == hour.hour {
                ranges[ranges.count - 1] = last.lowerBound..<(hour.hour + 1)
            } else {
                ranges.append(hour.hour..<(hour.hour + 1))
            }
        }
        return ranges
    }

    static func tooltipLines(for hour: BasalHourRecommendation) -> [TooltipLine] {
        guard let evidence = hour.insufficientEvidence else {
            return [
                TooltipLine(series: .pump, label: "Pump", value: String(format: "%.3f U/hr", hour.pumpRate)),
                TooltipLine(series: .loopTune, label: "LoopTune (unrounded)", value: String(format: "%.3f U/hr", hour.recommendedRate)),
                TooltipLine(series: nil, label: "Enter into Loop", value: String(format: "%.2f U/hr", hour.roundedRate())),
            ]
        }
        let pump = BasalHourRecommendation.formattedPumpRate(hour.pumpRate)
        var lines = [
            TooltipLine(series: nil, label: "Insufficient data", value: "no LoopTune rate"),
            TooltipLine(series: .pump, label: "Pump (keep)", value: "\(pump) U/hr"),
        ]
        guard let interpolated = hour.interpolatedRoundedRate() else {
            lines.append(TooltipLine(series: nil, label: "Interpolated", value: "none"))
            return lines
        }
        lines.append(TooltipLine(series: .interpolated, label: "Interpolated", value: String(format: "%.2f U/hr", interpolated)))
        lines.append(TooltipLine(series: nil, label: "Interpolated from", value: evidence.sourceTimes.joined(separator: " and ")))
        if let warning = hour.interpolatedGuardrailStatus()?.warning {
            lines.append(TooltipLine(series: nil, label: "Interpolated value", value: warning))
        }
        return lines
    }
}

/// 24-hour basal schedule: pump vs LoopTune as step lines. Hours with
/// insufficient data are shaded, have no LoopTune line, and show the
/// interpolated alternative dashed.
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

    private var points: [BasalChartData.Point] { BasalChartData.points(for: hours) }
    private var insufficientRanges: [Range<Int>] { BasalChartData.insufficientRanges(for: hours) }

    private func color(_ series: BasalChartData.Series) -> Color {
        switch series {
        case .pump: return ChartPalette.pump(colorScheme)
        case .loopTune: return ChartPalette.tuned(colorScheme)
        case .interpolated: return .orange
        }
    }

    private func stroke(_ series: BasalChartData.Series) -> StrokeStyle {
        series == .interpolated ? StrokeStyle(lineWidth: 2, dash: [5, 3]) : StrokeStyle(lineWidth: 2)
    }

    private var seriesDomain: [String] {
        var domain = [BasalChartData.Series.loopTune, .pump]
        if points.contains(where: { $0.series == .interpolated }) { domain.append(.interpolated) }
        return domain.map(\.rawValue)
    }

    private var seriesRange: [Color] {
        var range = [color(.loopTune), color(.pump)]
        if points.contains(where: { $0.series == .interpolated }) { range.append(color(.interpolated)) }
        return range
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Basal schedule — pump vs LoopTune (U/hr)")
                .font(.subheadline.weight(.semibold))
            Text("A mismatch observed in one hour tunes the previous three basal hours, because the insulin delivered there acts later.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !insufficientRanges.isEmpty {
                Label {
                    Text("Shaded hours had insufficient data. LoopTune has no rate for them: choose your pump rate or the dashed interpolated rate.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Chart {
                ForEach(insufficientRanges, id: \.lowerBound) { range in
                    RectangleMark(
                        xStart: .value("Start", range.lowerBound),
                        xEnd: .value("End", range.upperBound)
                    )
                    .foregroundStyle(Color.orange.opacity(0.10))
                }
                ForEach(points) { point in
                    LineMark(
                        x: .value("Hour", point.hour),
                        y: .value("U/hr", point.rate),
                        series: .value("Segment", point.segment)
                    )
                    .foregroundStyle(by: .value("Series", point.series.rawValue))
                    .interpolationMethod(.stepEnd)
                    .lineStyle(stroke(point.series))
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
                                ForEach(BasalChartData.tooltipLines(for: hovered), id: \.label) { line in
                                    TooltipRow(color: line.series.map(color), label: line.label, value: line.value)
                                }
                            }
                        }
                }
            }
            .chartForegroundStyleScale(domain: seriesDomain, range: seriesRange)
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

/// Per-hour basal data coverage: how much CGM time, in five-minute intervals,
/// informed each scheduled basal hour after the tuner's three-hour lookback.
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
            Text("Data coverage — CGM time informing each basal hour")
                .font(.subheadline.weight(.semibold))
            Chart {
                ForEach(hours, id: \.hour) { entry in
                    BarMark(
                        x: .value("Hour", entry.hour),
                        y: .value("5-min intervals", entry.sampleCount),
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
                                    label: "Data",
                                    value: hovered.sampleCount > 0 ? TuningReport.evidenceTime(hovered.sampleCount) : "no data"
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
                Text("Hours without bars had no direct basal evidence. They keep your pump rate, shown beside a rate interpolated from the nearest hours with evidence.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
