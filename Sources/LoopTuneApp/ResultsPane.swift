import SwiftUI
import LoopTuneKit

/// Right-hand results pane: empty/running/error/results states.
struct ResultsPane: View {
    let model: TuningViewModel

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                placeholder(icon: "waveform.path.ecg", title: "No analysis yet",
                            message: "Enter your Nightscout URL and choose how many days to analyze.")
            case .running:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Fetching and replaying your data…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                placeholder(icon: "exclamationmark.triangle", title: "Couldn't analyze", message: message, tint: .orange)
            case .done:
                if let recommendation = model.recommendation {
                    ResultsView(recommendation: recommendation)
                } else {
                    placeholder(icon: "questionmark", title: "No result", message: "")
                }
            }
        }
    }

    private func placeholder(icon: String, title: String, message: String, tint: Color = .secondary) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(tint)
            Text(title).font(.title3.weight(.semibold))
            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// The recommendation display.
struct ResultsView: View {
    let recommendation: TuningRecommendation
    @State private var displayUnit: GlucoseUnit

    init(recommendation: TuningRecommendation) {
        self.recommendation = recommendation
        // Default to the site's own unit.
        _displayUnit = State(initialValue: recommendation.profileGlucoseUnit)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DisclaimerBanner()

                HStack {
                    Text("Analyzed \(recommendation.daysAnalyzed) day(s), \(recommendation.totalSamples) samples")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Units", selection: $displayUnit) {
                        Text("mg/dL").tag(GlucoseUnit.milligramsPerDeciliter)
                        Text("mmol/L").tag(GlucoseUnit.millimolesPerLiter)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .labelsHidden()
                }

                HStack(spacing: 16) {
                    ParameterCard(rec: recommendation.sensitivity, displayUnit: displayUnit)
                    ParameterCard(rec: recommendation.carbRatio, displayUnit: displayUnit)
                }

                basalTable
            }
            .padding(20)
        }
    }

    private var basalTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Basal schedule (U/hr)")
                .font(.headline)
            HStack {
                Text("Hour").frame(width: 60, alignment: .leading)
                Text("Pump").frame(width: 80, alignment: .trailing)
                Text("LoopTune").frame(width: 90, alignment: .trailing)
                Text("").frame(maxWidth: .infinity)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            ForEach(recommendation.basalHours, id: \.hour) { hour in
                HStack {
                    Text(String(format: "%02d:00", hour.hour)).frame(width: 60, alignment: .leading)
                    Text(String(format: "%.3f", hour.pumpRate)).frame(width: 80, alignment: .trailing).monospacedDigit()
                    Text(String(format: "%.3f", hour.recommendedRate))
                        .frame(width: 90, alignment: .trailing).monospacedDigit()
                        .foregroundStyle(color(for: hour.changeTier))
                    if hour.untuned {
                        Text("no data").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .font(.callout)
            }
            Divider()
            HStack {
                Text("Daily total").frame(width: 60, alignment: .leading)
                Text(String(format: "%.2f", recommendation.pumpDailyBasal)).frame(width: 80, alignment: .trailing).monospacedDigit()
                Text(String(format: "%.2f", recommendation.tunedDailyBasal)).frame(width: 90, alignment: .trailing).monospacedDigit()
                Spacer()
            }
            .font(.callout.weight(.semibold))
        }
    }

    private func color(for tier: ChangeTier) -> Color {
        switch tier {
        case .minimal: return .primary
        case .notable: return .yellow
        case .large: return .orange
        }
    }
}

struct ParameterCard: View {
    let rec: ParameterRecommendation
    let displayUnit: GlucoseUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(rec.name).font(.subheadline.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(rec.formatted(rec.recommendedValue(in: displayUnit), in: displayUnit))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text(rec.unitLabel(in: displayUnit)).font(.caption).foregroundStyle(.secondary)
            }
            Text("was \(rec.formatted(rec.pumpValue(in: displayUnit), in: displayUnit))  ·  \(String(format: "%+.0f%%", rec.percentChange))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if rec.guardrailStatus != .ok {
                Text(rec.guardrailStatus == .atLimit ? "clamped to Loop limit" : "outside recommended range")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var color: Color {
        switch rec.changeTier {
        case .minimal: return .primary
        case .notable: return .yellow
        case .large: return .orange
        }
    }
}

struct DisclaimerBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Experimental analysis, not medical advice. Review every suggestion with your care team, change one setting at a time, and monitor closely.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
