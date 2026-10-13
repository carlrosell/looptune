import Foundation
import SwiftUI
import Testing
import LoopTuneKit
@testable import LoopTuneApp

@Suite("Saved diagnostics display")
struct DiagnosticsDisplayTests {
    #if compiler(>=6.2)
    @Test("an out-of-day glucose hour does not terminate the chart process")
    func outOfDayGlucoseHourDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            let data = try DiagnosticsDisplayTests.diagnosticsJSON(firstGlucoseHour: Int.max)
            if let diagnostics = try? JSONDecoder().decode(RunDiagnostics.self, from: data) {
                await MainActor.run {
                    let chart = HourlyGlucoseOutcomeView(diagnostics: diagnostics, displayUnit: .milligramsPerDeciliter)
                        .frame(width: 1_100)
                    _ = ImageRenderer(content: chart).nsImage
                }
            }
        }
    }
    #endif

    /// Diagnostics for two consecutive hours, the first moved to `firstGlucoseHour`.
    static func diagnosticsJSON(firstGlucoseHour: Int) throws -> Data {
        let diagnostics = RunDiagnostics(
            glucoseCount: 24, doseCount: 0, carbCount: 0,
            windowStart: Date(timeIntervalSince1970: 0), windowEnd: Date(timeIntervalSince1970: 7_200),
            daySummaries: [], hourlyDeviation: [],
            meanAbsDeviationBefore: 4, meanAbsDeviationAfter: 3,
            hourlyGlucose: (0..<2).map {
                HourlyValueDistribution(hour: $0, sampleCount: 12, p10: 80, p25: 95, median: 120, p75: 145, p90: 170)
            }
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostics)) as? [String: Any]
        )
        var glucose = try #require(object["hourlyGlucose"] as? [[String: Any]])
        glucose[0]["hour"] = firstGlucoseHour
        object["hourlyGlucose"] = glucose
        return try JSONSerialization.data(withJSONObject: object)
    }
}
