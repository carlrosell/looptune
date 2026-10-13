import SwiftUI
import LoopTuneKit

/// Sidebar: the connection/analysis form plus the persisted run history. The
/// list's selection binds to the shown run.
struct SidebarView: View {
    @Bindable var model: TuningViewModel

    var body: some View {
        List(selection: $model.selectedRunID) {
            Section("Nightscout") {
                TextField("Site URL", text: $model.urlString, prompt: Text("your-site.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                SecureField("Access token", text: $model.token, prompt: Text("Token (optional)"))
                    .textFieldStyle(.roundedBorder)
            }
            .disabled(model.isRunning)

            Section("Analysis") {
                Stepper(value: $model.days, in: 1...30) {
                    LabeledContent("History", value: "\(model.days) day\(model.days == 1 ? "" : "s")")
                }
                Picker("Insulin", selection: $model.insulinType) {
                    ForEach(InsulinType.allCases, id: \.self) { type in
                        Text(type.rawValue.capitalized).tag(type)
                    }
                }
            }
            .disabled(model.isRunning)

            Section {
                Button(action: model.run) {
                    HStack(spacing: 8) {
                        if model.isRunning {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.isRunning ? "Analyzing…" : "Analyze")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canRun)
            }

            if case .failed(let message) = model.phase {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if let notice = model.notice {
                Section {
                    Label(notice, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !model.runs.isEmpty {
                Section("Recent analyses") {
                    ForEach(model.runs) { run in
                        RunRow(run: run)
                            .tag(run.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    model.deleteRun(id: run.id)
                                }
                            }
                    }
                }
            }

            Section {
                Label {
                    Text("Experimental analysis—not medical advice. Review changes with your care team.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }
}

/// One row in the run history: when it ran, the site it analyzed, and the
/// headline changes.
struct RunRow: View {
    let run: SavedRun

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(run.createdAt, format: .dateTime.month().day().hour().minute())
                .font(.callout.weight(.medium))
            RunSourceLabel(source: run.source)
            Text(run.headline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

/// The site a saved run analyzed. It comes from the run, never the connection
/// form. Long origins are truncated in the middle so the scheme and port stay
/// visible; the tooltip holds the full value.
struct RunSourceLabel: View {
    let source: SavedRun.Source

    var body: some View {
        Text(source.label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(source.help)
    }
}

extension SavedRun.Source {
    /// The full source and, for a legacy record, what was not saved.
    var help: String {
        switch self {
        case .origin:
            return label
        case .host:
            return "\(label) (saved without its scheme and port)"
        case .unknown:
            return "This analysis was saved without its site."
        }
    }
}
