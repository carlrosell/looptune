import Testing
import Foundation
@testable import LoopTuneKit

@Suite("Evidence time")
struct EvidenceTimeTests {
    @Test("counts render as CGM time", arguments: [
        (intervals: -3, text: "0 min"),
        (intervals: 0, text: "0 min"),
        (intervals: 7, text: "35 min"),
        (intervals: 12, text: "1 h"),
        (intervals: 37, text: "3 h 5 min"),
        (intervals: Int.max / 5, text: "153722867280912930 h 5 min"),
        (intervals: Int.max / 5 + 1, text: "153722867280912930 h 10 min"),
        (intervals: Int.max, text: "768614336404564650 h 35 min"),
    ])
    func rendering(intervals: Int, text: String) {
        #expect(TuningReport.evidenceTime(intervals) == text)
    }

    @Test("counts that fit in minutes render as before")
    func matchesMinuteArithmetic() {
        for intervals in 0...10_000 {
            let minutes = intervals * 5
            let expected = minutes < 60
                ? "\(minutes) min"
                : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
            #expect(TuningReport.evidenceTime(intervals) == expected)
        }
    }
}

@Suite("Persisted diagnostics")
struct DiagnosticsDecodingTests {
    /// A saved run with a full day of deviation and glucose summaries.
    static func run(createdAt: Date) throws -> SavedRun {
        var run = try SyntheticHistory.run(createdAt: createdAt)
        run.diagnostics.hourlyDeviation = (0..<24).map {
            HourDeviation(hour: $0, before: 2.5, after: 1, sampleCount: 12)
        }
        run.diagnostics.hourlyGlucose = (0..<24).map {
            HourlyValueDistribution(hour: $0, sampleCount: 12, p10: 80, p25: 95, median: 120, p75: 145, p90: 170)
        }
        return run
    }

    /// `run` encoded by the current writer, with the entry at `index` of the
    /// diagnostics array `list` given `value` for `key`.
    static func runJSON(_ list: String, index: Int = 5, setting key: String, to value: Int) throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(run(createdAt: Date(timeIntervalSince1970: 0))))
                as? [String: Any]
        )
        var diagnostics = try #require(object["diagnostics"] as? [String: Any])
        var entries = try #require(diagnostics[list] as? [[String: Any]])
        entries[index][key] = value
        diagnostics[list] = entries
        object["diagnostics"] = diagnostics
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func decode(_ data: Data) throws -> SavedRun {
        try JSONDecoder().decode(SavedRun.self, from: data)
    }

    @Test("a saved run with full diagnostics round-trips")
    func validRunDecodes() throws {
        let run = try Self.run(createdAt: Date(timeIntervalSince1970: 0))
        #expect(try Self.decode(JSONEncoder().encode(run)) == run)
    }

    @Test("the largest representable deviation evidence count decodes")
    func largestEvidenceDecodes() throws {
        let data = try Self.runJSON("hourlyDeviation", setting: "sampleCount", to: Int.max / 5)
        #expect(try Self.decode(data).diagnostics.hourlyDeviation[5].sampleCount == Int.max / 5)
    }

    @Test("deviation evidence counts too large to be real are rejected", arguments: [
        Int.max, Int.max / 5 + 1,
    ])
    func oversizedEvidenceRejected(count: Int) throws {
        let data = try Self.runJSON("hourlyDeviation", setting: "sampleCount", to: count)
        #expect(throws: DecodingError.self) { try Self.decode(data) }
    }

    @Test("diagnostic hours outside the day are rejected", arguments: [
        "hourlyDeviation", "hourlyGlucose",
    ], [Int.max, Int.min, -1, 24])
    func outOfDayHoursRejected(list: String, hour: Int) throws {
        let data = try Self.runJSON(list, setting: "hour", to: hour)
        #expect(throws: DecodingError.self) { try Self.decode(data) }
    }

    #if compiler(>=6.2)
    @Test("an Int.max deviation evidence count does not terminate the display process")
    func maximumEvidenceDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            let data = try DiagnosticsDecodingTests.runJSON("hourlyDeviation", setting: "sampleCount", to: Int.max)
            if let run = try? DiagnosticsDecodingTests.decode(data) {
                _ = run.diagnostics.hourlyDeviation.map { TuningReport.evidenceTime($0.sampleCount) }
            }
        }
    }

    @Test("a deviation evidence count one past the limit does not terminate the display process")
    func oversizedEvidenceDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            let data = try DiagnosticsDecodingTests.runJSON("hourlyDeviation", setting: "sampleCount", to: Int.max / 5 + 1)
            if let run = try? DiagnosticsDecodingTests.decode(data) {
                _ = run.diagnostics.hourlyDeviation.map { TuningReport.evidenceTime($0.sampleCount) }
            }
        }
    }
    #endif

    @Test("corrupt diagnostics skip only the affected runs")
    func loadAllSkipsCorruptDiagnostics() throws {
        let store = RunStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("looptune-runs-\(UUID().uuidString)", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let older = try Self.run(createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        // Saved before hourly glucose summaries were recorded.
        var legacy = try Self.run(createdAt: Date(timeIntervalSince1970: 1_700_000_500))
        legacy.diagnostics.hourlyGlucose = nil
        #expect(store.save(older))
        #expect(store.save(legacy))

        let corruptions: [(list: String, key: String, value: Int)] = [
            ("hourlyDeviation", "sampleCount", Int.max),
            ("hourlyDeviation", "sampleCount", Int.max / 5 + 1),
            ("hourlyDeviation", "hour", Int.max),
            ("hourlyGlucose", "hour", Int.max),
        ]
        // Newer than the valid runs, so the corrupt files are read first.
        for (offset, corruption) in corruptions.enumerated() {
            let id = RunStore.makeID(createdAt: Date(timeIntervalSince1970: 1_700_100_000 + Double(offset)))
            var object = try #require(
                JSONSerialization.jsonObject(
                    with: Self.runJSON(corruption.list, setting: corruption.key, to: corruption.value)
                ) as? [String: Any]
            )
            object["id"] = id
            try JSONSerialization.data(withJSONObject: object)
                .write(to: store.directory.appendingPathComponent(id).appendingPathExtension("json"))
        }

        let loaded = store.loadAll()
        #expect(loaded.map(\.id) == [legacy.id, older.id])
        #expect(loaded == [legacy, older])
    }
}
