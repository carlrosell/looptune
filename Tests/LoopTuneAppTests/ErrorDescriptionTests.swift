import Foundation
import Testing
import LoopTuneKit
@testable import LoopTuneApp

@Suite("Analysis error descriptions")
@MainActor
struct ErrorDescriptionTests {
    @Test("an unsupported carb absorption time is described with its fix")
    func unsupportedCarbAbsorption() {
        let error = TuningPipeline.PipelineError.unsupportedCarbAbsorption(
            date: Date(timeIntervalSince1970: 1_699_810_200),
            grams: 60,
            absorptionTime: 12 * 3600,
            timeZone: TimeZone(identifier: "Europe/Stockholm")!
        )
        let description = TuningViewModel.describe(error)
        #expect(description == error.errorDescription)
        #expect(description.hasPrefix("The 60 g carb entry at 2023-11-12 18:30 (Europe/Stockholm)"))
        #expect(TuningViewModel.describe(TuningPipeline.PipelineError.noGlucose)
            == "Not enough glucose data in the selected window.")
    }

    @Test("a refused connection fails the run without showing the token")
    func refusedConnection() async throws {
        let token = "sec04-synthetic-token-91c2"
        let client = try NightscoutClient(rawURLString: "http://127.0.0.1:1", credentials: .token(token))
        let refused: any Error
        do {
            _ = try await client.fetchStatus()
            Issue.record("Nothing should listen on port 1")
            return
        } catch {
            refused = error
        }
        // The real client's error carries the token in its failing URL.
        #expect("\(refused)".contains(token))

        let suite = "LoopTuneTests.ErrorDescription.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runStore = RunStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("looptune-app-runs-\(UUID().uuidString)", isDirectory: true))
        let model = TuningViewModel(store: CredentialStore(defaults: defaults), runStore: runStore) { _ in throw refused }
        model.urlString = "http://127.0.0.1:1"
        model.token = token
        model.run()
        await model.runTask?.value

        let expected = "Could not connect to the Nightscout site. Check the address and that the site is running."
        #expect(TuningViewModel.describe(refused) == expected)
        #expect(model.phase == .failed(expected))
    }
}
