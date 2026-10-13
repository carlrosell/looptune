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

@Suite("Persisted basal hours")
struct BasalHourDecodingTests {
    /// A saved recommendation encoded by the current writer, passed through
    /// `corrupt` before re-serialization.
    static func recommendationJSON(_ corrupt: (inout [String: Any]) throws -> Void) throws -> Data {
        let recommendation = try SyntheticHistory.run(createdAt: Date(timeIntervalSince1970: 0)).recommendation
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(recommendation)) as? [String: Any]
        )
        try corrupt(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func recommendationJSON(basalHour index: Int, setting key: String, to value: Int) throws -> Data {
        try recommendationJSON { object in
            var hours = try #require(object["basalHours"] as? [[String: Any]])
            hours[index][key] = value
            object["basalHours"] = hours
        }
    }

    static func decode(_ data: Data) throws -> TuningRecommendation {
        try JSONDecoder().decode(TuningRecommendation.self, from: data)
    }

    @Test("the saved basal schedule round-trips")
    func validHoursDecode() throws {
        let decoded = try Self.decode(Self.recommendationJSON { _ in })
        #expect(decoded.basalHours.map(\.hour) == Array(0..<24))
    }

    @Test("basal hours outside the day are rejected", arguments: [Int.max, -1, 24, 99])
    func outOfDayHoursRejected(hour: Int) throws {
        let data = try Self.recommendationJSON(basalHour: 5, setting: "hour", to: hour)
        #expect(throws: DecodingError.self) { try Self.decode(data) }
    }

    @Test("a duplicate basal hour is rejected")
    func duplicateHourRejected() throws {
        let data = try Self.recommendationJSON(basalHour: 5, setting: "hour", to: 4)
        #expect(throws: DecodingError.self) { try Self.decode(data) }
    }

    @Test("a missing basal hour is rejected")
    func missingHourRejected() throws {
        let data = try Self.recommendationJSON { object in
            var hours = try #require(object["basalHours"] as? [[String: Any]])
            hours.removeLast()
            object["basalHours"] = hours
        }
        #expect(throws: DecodingError.self) { try Self.decode(data) }
    }

    @Test("evidence counts too large to display are rejected", arguments: [
        "sampleCount", "totalSamples", "excludedOverrideSamples",
    ])
    func oversizedEvidenceRejected(key: String) throws {
        let largest = Int.max / 5
        let valid = key == "sampleCount"
            ? try Self.recommendationJSON(basalHour: 5, setting: key, to: largest)
            : try Self.recommendationJSON { $0[key] = largest }
        #expect(throws: Never.self) { try Self.decode(valid) }

        let data = key == "sampleCount"
            ? try Self.recommendationJSON(basalHour: 5, setting: key, to: largest + 1)
            : try Self.recommendationJSON { $0[key] = largest + 1 }
        #expect(throws: DecodingError.self) { try Self.decode(data) }
    }

    #if compiler(>=6.2)
    @Test("an out-of-day basal hour does not terminate the display process")
    func outOfDayHourDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            // A rate unlike its neighbours keeps the entry from being merged
            // into the previous Loop schedule row.
            let data = try BasalHourDecodingTests.recommendationJSON { object in
                var hours = try #require(object["basalHours"] as? [[String: Any]])
                hours[5]["hour"] = Int.max
                hours[5]["recommendedRate"] = 0.8
                object["basalHours"] = hours
            }
            if let decoded = try? BasalHourDecodingTests.decode(data) {
                _ = decoded.loopBasalSchedule()
            }
        }
    }

    @Test("an oversized evidence count does not terminate the display process")
    func oversizedEvidenceDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            let data = try BasalHourDecodingTests.recommendationJSON { $0["totalSamples"] = Int.max }
            if let decoded = try? BasalHourDecodingTests.decode(data) {
                _ = TuningReport.render(decoded)
            }
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

    @Test("corrupt basal hours and evidence counts skip only the affected run")
    func loadAllSkipsCorruptBasalHours() throws {
        let store = RunStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("looptune-runs-\(UUID().uuidString)", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let valid = try SyntheticHistory.run(createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(store.save(valid))
        let corrupt = try SyntheticHistory.writeCorruptBasalRuns(
            to: store.directory,
            from: valid,
            createdAt: Date(timeIntervalSince1970: 1_700_100_000)
        )
        #expect(corrupt == 8)

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
            try writeCopy(of: run, to: directory, createdAt: createdAt) { recommendation in
                var schedule = try #require(recommendation["sensitivitySchedule"] as? [[String: Any]])
                if let remove = corruption.remove { schedule[0].removeValue(forKey: remove) }
                schedule[0][corruption.key] = corruption.value
                recommendation["sensitivitySchedule"] = schedule
            }
        }
        return corruptions.count
    }

    /// Writes copies of `run` with an out-of-day, duplicate, or missing basal
    /// hour, or an evidence count too large to display. Returns the number of
    /// files written.
    static func writeCorruptBasalRuns(to directory: URL, from run: SavedRun, createdAt: Date) throws -> Int {
        var corruptions: [(inout [String: Any]) throws -> Void] = [Int.max, -1, 24, 99].map { hour in
            { recommendation in
                var hours = try #require(recommendation["basalHours"] as? [[String: Any]])
                hours[5]["hour"] = hour
                recommendation["basalHours"] = hours
            }
        }
        corruptions.append { recommendation in
            var hours = try #require(recommendation["basalHours"] as? [[String: Any]])
            hours[5]["hour"] = 4
            recommendation["basalHours"] = hours
        }
        corruptions.append { recommendation in
            var hours = try #require(recommendation["basalHours"] as? [[String: Any]])
            hours.removeLast()
            recommendation["basalHours"] = hours
        }
        corruptions.append { recommendation in
            var hours = try #require(recommendation["basalHours"] as? [[String: Any]])
            hours[5]["sampleCount"] = Int.max
            recommendation["basalHours"] = hours
        }
        corruptions.append { recommendation in
            recommendation["totalSamples"] = Int.max
        }
        for corrupt in corruptions {
            try writeCopy(of: run, to: directory, createdAt: createdAt, corrupt: corrupt)
        }
        return corruptions.count
    }

    private static func writeCopy(
        of run: SavedRun,
        to directory: URL,
        createdAt: Date,
        corrupt: (inout [String: Any]) throws -> Void
    ) throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any]
        )
        var recommendation = try #require(object["recommendation"] as? [String: Any])
        try corrupt(&recommendation)
        object["recommendation"] = recommendation
        let id = RunStore.makeID(createdAt: createdAt)
        object["id"] = id
        try JSONSerialization.data(withJSONObject: object)
            .write(to: directory.appendingPathComponent(id).appendingPathExtension("json"))
    }
}
