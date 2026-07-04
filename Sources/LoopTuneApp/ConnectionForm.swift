import SwiftUI
import LoopTuneKit

/// Left-hand connection + options form.
struct ConnectionForm: View {
    @Bindable var model: TuningViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                section("Nightscout") {
                    labeledField("Site URL") {
                        TextField("https://your-site.example.com", text: $model.urlString)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledField("Access token (optional)") {
                        SecureField("token", text: $model.token)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                section("Analysis") {
                    labeledField("Days of history: \(model.days)") {
                        Slider(value: Binding(
                            get: { Double(model.days) },
                            set: { model.days = Int($0) }
                        ), in: 1...30, step: 1)
                    }
                    labeledField("Insulin type") {
                        Picker("", selection: $model.insulinType) {
                            ForEach(InsulinType.allCases, id: \.self) { type in
                                Text(type.rawValue.capitalized).tag(type)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }

                Button(action: model.run) {
                    HStack {
                        if model.phase == .running {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.phase == .running ? "Analyzing…" : "Analyze")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canRun)

                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LoopTune")
                .font(.largeTitle.bold())
            Text("Tune Loop settings from your Nightscout history.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func labeledField(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout)
            content()
        }
    }
}
