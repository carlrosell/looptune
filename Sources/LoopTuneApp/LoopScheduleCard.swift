import SwiftUI
import AppKit
import LoopTuneKit

/// The recommended basal schedule presented exactly like Loop's "Basal Rates"
/// entry screen: one row per change point (start time + rate), so it can be
/// transcribed into Loop line by line.
struct LoopScheduleCard: View {
    let recommendation: TuningRecommendation
    @State private var copied = false
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
        } accessory: {
            Button {
                copyToPasteboard()
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Copy the schedule as text")
        }
    }

    /// Loop shows rates without trailing zeros (0.2, 0.25), locale-aware.
    private func formatted(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(1...2)))
    }

    private func copyToPasteboard() {
        let text = entries
            .map { "\($0.timeString)\t\(formatted($0.rate)) U/hr" }
            .joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
