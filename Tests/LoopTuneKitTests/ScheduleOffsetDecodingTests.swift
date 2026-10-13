import Testing
import Foundation
@testable import LoopTuneKit

@Suite("Persisted schedule offsets")
struct ScheduleOffsetDecodingTests {
    /// A schedule entry encoded by the current writer, with `key` replaced by
    /// `value` and `removing` dropped.
    static func entryJSON(setting key: String, to value: Int, removing: String? = nil) throws -> Data {
        let entry = try SyntheticHistory.run(createdAt: Date(timeIntervalSince1970: 0))
            .recommendation.sensitivitySchedule[0]
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]
        )
        if let removing { object.removeValue(forKey: removing) }
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func legacyJSON(startMinutes: Int) throws -> Data {
        try entryJSON(setting: "startMinutes", to: startMinutes, removing: "secondsSinceMidnight")
    }

    @Test("valid legacy and current offsets decode", arguments: [
        (key: "startMinutes", value: 0, seconds: 0),
        (key: "startMinutes", value: 1_439, seconds: 86_340),
        (key: "secondsSinceMidnight", value: 0, seconds: 0),
        (key: "secondsSinceMidnight", value: 86_399, seconds: 86_399),
    ])
    func validOffsets(key: String, value: Int, seconds: Int) throws {
        let data = key == "startMinutes"
            ? try Self.legacyJSON(startMinutes: value)
            : try Self.entryJSON(setting: key, to: value)
        let decoded = try JSONDecoder().decode(ParameterScheduleRecommendation.self, from: data)
        #expect(decoded.secondsSinceMidnight == seconds)
    }

    @Test("legacy minute offsets outside one day are rejected", arguments: [
        Int.max, Int.min, Int.max / 60 + 1, -1, 1_440,
    ])
    func invalidLegacyOffsets(minutes: Int) throws {
        let data = try Self.legacyJSON(startMinutes: minutes)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ParameterScheduleRecommendation.self, from: data)
        }
    }

    @Test("current second offsets outside one day are rejected", arguments: [
        Int.max, Int.min, -1, 86_400,
    ])
    func invalidCurrentOffsets(seconds: Int) throws {
        let data = try Self.entryJSON(setting: "secondsSinceMidnight", to: seconds)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ParameterScheduleRecommendation.self, from: data)
        }
    }

    #if compiler(>=6.2)
    @Test("an overflowing legacy offset does not terminate the decoding process")
    func overflowingLegacyOffsetDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            let data = try ScheduleOffsetDecodingTests.legacyJSON(startMinutes: Int.max)
            _ = try? JSONDecoder().decode(ParameterScheduleRecommendation.self, from: data)
        }
    }
    #endif
}

@Suite("RunStore corrupt history")
struct RunStoreCorruptHistoryTests {
    @Test("corrupt schedule offsets skip only the affected run")
    func loadAllSkipsCorruptOffsets() throws {
        let store = RunStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("looptune-runs-\(UUID().uuidString)", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let valid = try SyntheticHistory.run(createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(store.save(valid))
        // Newer than the valid run, so the corrupt files are read first.
        let corrupt = try SyntheticHistory.writeCorruptRuns(
            to: store.directory,
            from: valid,
            createdAt: Date(timeIntervalSince1970: 1_700_100_000)
        )
        #expect(corrupt == 4)

        #expect(store.loadAll().map(\.id) == [valid.id])
    }
}

/// Synthetic saved runs for history-loading tests.
enum SyntheticHistory {
    static func run(createdAt: Date) throws -> SavedRun {
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

    /// Writes copies of `run` whose first sensitivity entry carries an invalid
    /// legacy or current offset. Returns the number of files written.
    static func writeCorruptRuns(to directory: URL, from run: SavedRun, createdAt: Date) throws -> Int {
        let corruptions: [(remove: String?, key: String, value: Int)] = [
            ("secondsSinceMidnight", "startMinutes", Int.max),
            ("secondsSinceMidnight", "startMinutes", -1),
            (nil, "secondsSinceMidnight", 86_400),
            (nil, "secondsSinceMidnight", Int.min),
        ]
        for corruption in corruptions {
            var object = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any]
            )
            var recommendation = try #require(object["recommendation"] as? [String: Any])
            var schedule = try #require(recommendation["sensitivitySchedule"] as? [[String: Any]])
            if let remove = corruption.remove { schedule[0].removeValue(forKey: remove) }
            schedule[0][corruption.key] = corruption.value
            recommendation["sensitivitySchedule"] = schedule
            object["recommendation"] = recommendation
            let id = RunStore.makeID(createdAt: createdAt)
            object["id"] = id
            try JSONSerialization.data(withJSONObject: object)
                .write(to: directory.appendingPathComponent(id).appendingPathExtension("json"))
        }
        return corruptions.count
    }
}
