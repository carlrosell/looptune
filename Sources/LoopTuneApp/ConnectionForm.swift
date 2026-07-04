import SwiftUI
import LoopTuneKit

/// Sidebar configuration form, using the native grouped form style.
struct ConnectionForm: View {
    @Bindable var model: TuningViewModel

    var body: some View {
        Form {
            Section {
                TextField("Site URL", text: $model.urlString, prompt: Text("your-site.example.com"))
                    .autocorrectionDisabled()
                SecureField("Access token", text: $model.token, prompt: Text("Optional"))
            } header: {
                Text("Nightscout")
            } footer: {
                Text("A token with the readable role is only needed for private sites.")
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
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(model.phase == .running ? "Analyzing…" : "Analyze")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canRun)
            } footer: {
                Text("Experimental analysis, not medical advice. Review results with your care team.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
