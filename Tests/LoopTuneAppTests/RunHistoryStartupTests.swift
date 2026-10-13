import Foundation
import Testing
import LoopTuneKit
@testable import LoopTuneApp

@Suite("Run history at startup")
@MainActor
struct RunHistoryStartupTests {
    @Test("a run with a corrupt schedule offset does not hide the valid history")
    func startupSkipsCorruptRun() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("looptune-runs-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "looptune-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let runStore = RunStore(directory: directory)
        let valid = try Self.run(createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(runStore.save(valid))

        // A newer copy whose legacy offset overflows when converted to seconds.
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any]
        )
        var recommendation = try #require(object["recommendation"] as? [String: Any])
        var schedule = try #require(recommendation["sensitivitySchedule"] as? [[String: Any]])
        schedule[0].removeValue(forKey: "secondsSinceMidnight")
        schedule[0]["startMinutes"] = Int.max
        recommendation["sensitivitySchedule"] = schedule
        object["recommendation"] = recommendation
        let corruptID = RunStore.makeID(createdAt: Date(timeIntervalSince1970: 1_700_100_000))
        object["id"] = corruptID
        try JSONSerialization.data(withJSONObject: object)
            .write(to: directory.appendingPathComponent(corruptID).appendingPathExtension("json"))

        let model = TuningViewModel(store: CredentialStore(defaults: defaults), runStore: runStore)
        #expect(model.runs.map(\.id) == [valid.id])
        #expect(model.selectedRunID == valid.id)
    }

    private static func run(createdAt: Date) throws -> SavedRun {
        let output = TuningOutput(
            tunedBasalHourly: Array(repeating: 1.0, count: 24),
            pumpBasalHourly: Array(repeating: 1.0, count: 24),
            untunedBasalHours: Array(repeating: false, count: 24),
            tunedISF: 50, pumpISF: 50, tunedCarbRatio: 10, pumpCarbRatio: 10,
            categoryCounts: [:], totalSamples: 10
        )
        let recommendation = try TuningRecommendation(from: output, daysAnalyzed: 1)
        let diagnostics = RunDiagnostics(
            glucoseCount: 288, doseCount: 5, carbCount: 2,
            windowStart: createdAt, windowEnd: createdAt,
            daySummaries: [], hourlyDeviation: [],
            meanAbsDeviationBefore: 4, meanAbsDeviationAfter: 3
        )
        return SavedRun(
            id: RunStore.makeID(createdAt: createdAt), createdAt: createdAt, siteHost: "site",
            days: 1, insulinType: .novolog, recommendation: recommendation, diagnostics: diagnostics
        )
    }
}
