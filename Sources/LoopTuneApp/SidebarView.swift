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

            Section {
                Button(action: model.run) {
                    HStack(spacing: 8) {
                        if model.phase == .running {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.phase == .running ? "Analyzing…" : "Analyze")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canRun)
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
        }
        .listStyle(.sidebar)
    }
}

/// One row in the run history: when it ran and the headline changes.
struct RunRow: View {
    let run: SavedRun

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(run.createdAt, format: .dateTime.month().day().hour().minute())
                .font(.callout.weight(.medium))
            Text(run.headline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}
