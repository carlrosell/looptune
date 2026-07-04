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
}

/// 24-hour basal schedule: pump vs LoopTune as step lines.
struct BasalChartView: View {
    let hours: [BasalHourRecommendation]
    @Environment(\.colorScheme) private var colorScheme

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
            Chart(points) { point in
                LineMark(
                    x: .value("Hour", point.hour),
                    y: .value("U/hr", point.rate)
                )
                .foregroundStyle(by: .value("Series", point.series))
                .interpolationMethod(.stepEnd)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartForegroundStyleScale([
                "LoopTune": ChartPalette.tuned(colorScheme),
                "Pump": ChartPalette.pump(colorScheme),
            ])
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

/// Per-hour basal data coverage: how many deviation samples informed each hour.
/// Hours with no samples appear as gaps (and are flagged in the table below).
struct CoverageChartView: View {
    let hours: [BasalHourRecommendation]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Data coverage — basal samples per hour")
                .font(.subheadline.weight(.semibold))
            Chart(hours, id: \.hour) { entry in
                BarMark(
                    x: .value("Hour", entry.hour),
                    y: .value("Samples", entry.sampleCount),
                    width: .fixed(8)
                )
                .foregroundStyle(ChartPalette.tuned(colorScheme))
                .cornerRadius(2)
            }
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
                Text("Hours without bars had no basal-attributed data; their recommendations are interpolated from neighbors.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
