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
            subtitle: "\(entries.count) entr\(entries.count == 1 ? "y" : "ies"), matching Loop's schedule screen"
        ) {
            Table(entries, selection: $selection) {
                TableColumn("Time") { entry in
                    Text(entry.timeString)
                        .monospacedDigit()
                }
                .width(min: 56, ideal: 72)

                TableColumn("Rate") { entry in
                    HStack(spacing: 4) {
                        Text(formatted(entry.rate))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                        Text("U/hr")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .resultsTable(rowCount: entries.count)
        }
    }

    /// Loop shows rates without trailing zeros (0.2, 0.25), locale-aware.
    private func formatted(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(1...2)))
    }
}
