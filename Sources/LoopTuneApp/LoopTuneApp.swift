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
                .frame(minWidth: 780, minHeight: 560)
        }
    }
}

struct ContentView: View {
    @State private var model = TuningViewModel()

    var body: some View {
        NavigationSplitView {
            ConnectionForm(model: model)
                .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 400)
        } detail: {
            ResultsPane(model: model)
                .frame(minWidth: 460)
        }
        .navigationTitle("LoopTune")
        .navigationSubtitle(subtitle)
    }

    /// Window subtitle: a quiet summary of the last analysis.
    private var subtitle: String {
        guard case .done = model.phase, let rec = model.recommendation else { return "" }
        return "\(rec.daysAnalyzed) day\(rec.daysAnalyzed == 1 ? "" : "s") · \(rec.totalSamples) samples"
    }
}
