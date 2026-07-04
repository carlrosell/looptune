import SwiftUI
import LoopTuneKit

@main
struct LoopTuneApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("LoopTune")
                .font(.largeTitle.bold())
            Text("v\(LoopTuneKit.version) — UI coming soon")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}
