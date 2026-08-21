import SwiftUI
import LoopTuneKit

/// Running as a bare SPM executable (no .app bundle) leaves the process in the
/// "prohibited" activation policy: the window renders but can never take focus.
/// Promote to a regular foreground app and activate on launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct LoopTuneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 860, minHeight: 600)
        }
    }
}

struct ContentView: View {
    @State private var model = TuningViewModel()
    @State private var showingDisplaySettings = false
    /// An empty value means "follow the selected Nightscout profile" until the
    /// user makes an explicit app-wide choice.
    @AppStorage("displayGlucoseUnit") private var storedDisplayUnit = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 400)
        } detail: {
            DetailPane(model: model, displayUnit: displayUnit)
                .frame(minWidth: 520)
        }
        .navigationTitle("LoopTune")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingDisplaySettings.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "gearshape")
                        Text(displayUnit.shortLabel)
                    }
                }
                .help("Display settings")
                .popover(isPresented: $showingDisplaySettings, arrowEdge: .bottom) {
                    DisplaySettingsPanel(displayUnit: displayUnitBinding)
                }
            }
        }
    }

    private var displayUnit: GlucoseUnit {
        GlucoseUnit(rawValue: storedDisplayUnit)
            ?? model.selectedRun?.recommendation.profileGlucoseUnit
            ?? .milligramsPerDeciliter
    }

    private var displayUnitBinding: Binding<GlucoseUnit> {
        Binding(
            get: { displayUnit },
            set: { storedDisplayUnit = $0.rawValue }
        )
    }

    private var subtitle: String {
        guard let run = model.selectedRun else { return "" }
        return "\(run.days) day\(run.days == 1 ? "" : "s") · \(run.recommendation.totalSamples) samples"
    }
}

struct DisplaySettingsPanel: View {
    @Binding var displayUnit: GlucoseUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Display settings")
                .font(.headline)
            Picker("Glucose unit", selection: $displayUnit) {
                Text("mg/dL").tag(GlucoseUnit.milligramsPerDeciliter)
                Text("mmol/L").tag(GlucoseUnit.millimolesPerLiter)
            }
            .pickerStyle(.radioGroup)
            Text("This unit is used for every glucose value, chart, tooltip, and table in the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 260)
    }
}
