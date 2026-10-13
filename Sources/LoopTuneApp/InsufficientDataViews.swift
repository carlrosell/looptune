import SwiftUI
import LoopTuneKit

/// Explains blocks without sufficient evidence of their own (ADR 0011): their
/// pump value and interpolated alternative are both shown, and the user
/// chooses which to enter.
struct InsufficientDataNotes: View {
    let notes: [String]

    var body: some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(notes, id: \.self) { note in
                    Label {
                        Text(note)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// One note per schedule block with insufficient data.
    static func notes(for entries: [ParameterScheduleRecommendation]) -> [String] {
        entries.compactMap { entry in
            entry.insufficientEvidence.map { "\(entry.timeString): \($0.note)" }
        }
    }

    /// One note per run of consecutive basal hours with insufficient data and
    /// the same sources.
    static func notes(for hours: [BasalHourRecommendation]) -> [String] {
        var groups: [(start: Int, end: Int, evidence: InsufficientEvidence<Double>)] = []
        for hour in hours.sorted(by: { $0.hour < $1.hour }) {
            guard let evidence = hour.insufficientEvidence else { continue }
            if let last = groups.last, last.end == hour.hour, last.evidence.sources == evidence.sources {
                groups[groups.count - 1].end = hour.hour + 1
            } else {
                groups.append((hour.hour, hour.hour + 1, evidence))
            }
        }
        return groups.map { group in
            let range = String(format: "%02d:00–%02d:00", group.start, group.end)
            return "\(range): \(group.evidence.note)"
        }
    }
}

/// The two values for a block with insufficient data: the pump value and,
/// when one exists, the interpolated alternative.
struct ChoiceText: View {
    let pump: String
    let interpolated: String?
    var interpolatedColor: Color = .primary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help("Insufficient data: choose the pump value or the interpolated value.")
            Text(pump)
            if let interpolated {
                Text("or").foregroundStyle(.secondary)
                Text(interpolated)
                    .fontWeight(.semibold)
                    .foregroundStyle(interpolatedColor)
            }
        }
    }
}

extension ChangeTier {
    var color: Color {
        switch self {
        case .minimal: return .primary
        case .notable: return .yellow
        case .large: return .orange
        }
    }
}
