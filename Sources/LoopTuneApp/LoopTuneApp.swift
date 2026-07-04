import SwiftUI
import LoopTuneKit

@main
struct LoopTuneApp: App {
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
