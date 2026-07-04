import SwiftUI
import AppKit
import LoopTuneKit

/// The recommended basal schedule presented exactly like Loop's "Basal Rates"
/// entry screen: one row per change point (start time + rate), so it can be
/// transcribed into Loop line by line.
struct LoopScheduleCard: View {
    let recommendation: TuningRecommendation
    @State private var copied = false

    private var entries: [LoopBasalEntry] {
        recommendation.loopBasalSchedule()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Basal Rates — as entered in Loop")
                        .font(.headline)
                    Text("\(entries.count) entr\(entries.count == 1 ? "y" : "ies"), matching Loop's schedule screen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copyToPasteboard()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy the schedule as text")
            }

            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    HStack {
                        Text(entry.timeString)
                            .font(.body.monospacedDigit())
                        Spacer()
                        Text(formatted(entry.rate))
                            .font(.body.weight(.semibold).monospacedDigit())
                        Text("U/hr")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    if index < entries.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
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
