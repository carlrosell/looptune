import SwiftUI
import LoopTuneKit

/// The recommended basal schedule presented exactly like Loop's "Basal Rates"
/// entry screen: one row per change point (start time + rate), so it can be
/// transcribed into Loop line by line.
struct LoopScheduleCard: View {
    let recommendation: TuningRecommendation
    /// Finder-style multi-selection for ticking off rows entered into Loop.
    @State private var selection = Set<Int>()

    private var entries: [LoopBasalEntry] {
        recommendation.loopBasalSchedule()
    }

    var body: some View {
        TableCard(
            title: "Basal Rates — as entered in Loop",
            subtitle: subtitle
        ) {
            Table(entries, selection: $selection) {
                TableColumn("Time") { entry in
                    Text(entry.timeString)
                        .monospacedDigit()
                }
                .width(min: 56, ideal: 72)

                TableColumn("Rate") { entry in
                    HStack(spacing: 4) {
                        if let insufficient = entry.insufficientEvidence {
                            ChoiceText(
                                pump: formattedPump(entry.rate),
                                interpolated: insufficient.interpolated.map(formatted),
                                interpolatedStatus: entry.interpolatedGuardrailStatus ?? .ok
                            )
                            .monospacedDigit()
                        } else {
                            Text(formatted(entry.rate))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        Text("U/hr")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 90, ideal: 130)

                TableColumn("Data") { entry in
                    if let insufficient = entry.insufficientEvidence {
                        Text(insufficient.interpolated == nil
                             ? "Insufficient data · pump rate only"
                             : "Insufficient data · from \(insufficient.sourceTimes.joined(separator: " and "))")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .resultsTable(rowCount: entries.count)
        }
    }

    private var subtitle: String {
        var text = "\(entries.count) entr\(entries.count == 1 ? "y" : "ies"), matching Loop's schedule screen"
        if entries.contains(where: { $0.insufficientEvidence != nil }) {
            text += ". Entries with a warning had insufficient data: enter your pump rate or the interpolated rate."
        }
        return text
    }

    /// Loop shows rates without trailing zeros (0.2, 0.25), locale-aware.
    private func formatted(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(1...2)))
    }

    /// A pump rate the user may keep, at the precision it was stored with.
    private func formattedPump(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(1...3)))
    }
}
