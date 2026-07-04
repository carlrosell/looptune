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
        WindowGroup("LoopTune") {
            ContentView()
                .frame(minWidth: 720, minHeight: 560)
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @State private var model = TuningViewModel()

    var body: some View {
        HSplitView {
            ConnectionForm(model: model)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)

            ResultsPane(model: model)
                .frame(minWidth: 400)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("LoopTune")
                    .font(.headline)
            }
        }
    }
}
