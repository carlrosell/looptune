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

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 400)
        } detail: {
            DetailPane(model: model)
                .frame(minWidth: 520)
        }
        .navigationTitle("LoopTune")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        guard let run = model.selectedRun else { return "" }
        return "\(run.days) day\(run.days == 1 ? "" : "s") · \(run.recommendation.totalSamples) samples"
    }
}
