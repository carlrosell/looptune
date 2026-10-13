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
        VStack(alignment: .leading, spacing: 8) {
            table
            InsufficientDataNotes(notes: InsufficientDataNotes.notes(for: entries))
        }
    }

    private var table: some View {
        TableCard(
            title: title,
            subtitle: "Uses your Loop time blocks, or six-hour blocks when Loop has one all-day value. A block without enough data of its own has no recommendation: it shows your pump value and a value interpolated from the nearest blocks with enough data."
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
                    if let insufficient = entry.insufficientEvidence {
                        ChoiceText(
                            pump: entry.parameter.formattedPumpValue(in: displayUnit),
                            interpolated: insufficient.interpolated.map {
                                "\($0.formatted($0.recommendedValue(in: displayUnit), in: displayUnit)) interpolated"
                            },
                            interpolatedColor: insufficient.interpolated?.changeTier.color ?? .primary,
                            interpolatedStatus: insufficient.interpolated?.guardrailStatus ?? .ok
                        )
                        .numericCell()
                    } else {
                        HStack(spacing: 5) {
                            value(entry.parameter.recommendedValue(in: displayUnit), for: entry.parameter)
                                .fontWeight(.semibold)
                            if let warning = entry.parameter.guardrailStatus.warning {
                                GuardrailWarningIcon(message: warning.prefix(1).uppercased() + warning.dropFirst())
                            }
                        }
                        .foregroundStyle(entry.parameter.changeTier.color)
                        .numericCell()
                    }
                }
                .width(min: 82, ideal: 170)

                TableColumn("Data") { entry in
                    if entry.insufficientEvidence != nil {
                        Text("Insufficient data · \(entry.evidenceDescription(evidenceName))")
                            .foregroundStyle(.orange)
                    } else {
                        Text(entry.evidenceDescription(evidenceName))
                            .foregroundStyle(entry.untuned || entry.daysMissing > 0 ? .tertiary : .secondary)
                    }
                }
            }
            .resultsTable(rowCount: entries.count)
        }
    }

    private func value(_ value: Double, for parameter: ParameterRecommendation) -> Text {
        Text("\(parameter.formatted(value, in: displayUnit)) \(parameter.unitLabel(in: displayUnit))")
    }
}
