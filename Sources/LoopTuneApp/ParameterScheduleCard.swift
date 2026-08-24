import SwiftUI
import LoopTuneKit

/// A time-of-day ISF or carb-ratio schedule using the blocks already present in
/// Loop. Users can transcribe each recommendation without losing its start time.
struct ParameterScheduleCard: View {
    let title: String
    let entries: [ParameterScheduleRecommendation]
    let evidenceName: String
    let displayUnit: GlucoseUnit
    @State private var selection = Set<Int>()

    var body: some View {
        TableCard(
            title: title,
            subtitle: "Uses your existing Loop time blocks. Blocks without enough data stay unchanged."
        ) {
            Table(entries, selection: $selection) {
                TableColumn("Time") { entry in
                    Text(entry.timeString)
                        .monospacedDigit()
                }
                .width(min: 56, ideal: 72)

                TableColumn("Pump") { entry in
                    value(entry.parameter.pumpValue(in: displayUnit), for: entry.parameter)
                        .foregroundStyle(.secondary)
                        .numericCell()
                }
                .width(min: 72, ideal: 88)

                TableColumn("LoopTune") { entry in
                    HStack(spacing: 5) {
                        value(entry.parameter.recommendedValue(in: displayUnit), for: entry.parameter)
                            .fontWeight(.semibold)
                        if entry.parameter.guardrailStatus != .ok {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(guardrailMessage(entry.parameter.guardrailStatus))
                        }
                    }
                    .foregroundStyle(color(for: entry.parameter.changeTier))
                    .numericCell()
                }
                .width(min: 82, ideal: 96)

                TableColumn("Data") { entry in
                    Text(entry.evidenceDescription(evidenceName))
                        .foregroundStyle(entry.untuned || entry.daysMissing > 0 ? .tertiary : .secondary)
                }
            }
            .resultsTable(rowCount: entries.count)
        }
    }

    private func value(_ value: Double, for parameter: ParameterRecommendation) -> Text {
        Text("\(parameter.formatted(value, in: displayUnit)) \(parameter.unitLabel(in: displayUnit))")
    }

    private func color(for tier: ChangeTier) -> Color {
        switch tier {
        case .minimal: return .primary
        case .notable: return .yellow
        case .large: return .orange
        }
    }

    private func guardrailMessage(_ status: LoopGuardrails.Status) -> String {
        status == .atLimit ? "Clamped to Loop's limit" : "Outside Loop's recommended range"
    }
}
