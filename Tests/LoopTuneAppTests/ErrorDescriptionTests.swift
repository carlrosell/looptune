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
}
