import Testing
import Foundation
@testable import LoopTuneKit

@Suite("Recommendation Codable")
struct RecommendationCodableTests {
    private func sampleRecommendation() -> TuningRecommendation {
        let output = TuningOutput(
            tunedBasalHourly: Array(repeating: 1.1, count: 24),
            pumpBasalHourly: Array(repeating: 1.0, count: 24),
            untunedBasalHours: Array(repeating: false, count: 24),
            sensitivitySchedule: [
                ScheduleTuningOutput(secondsSinceMidnight: 0, tunedValue: 48, pumpValue: 50, untuned: false, evidenceCount: 20),
                ScheduleTuningOutput(secondsSinceMidnight: 12 * 3600, tunedValue: 58, pumpValue: 60, untuned: false, evidenceCount: 18),
            ],
            carbRatioSchedule: [
                ScheduleTuningOutput(secondsSinceMidnight: 0, tunedValue: 9.5, pumpValue: 10, untuned: false, evidenceCount: 3),
                ScheduleTuningOutput(secondsSinceMidnight: 12 * 3600, tunedValue: 11, pumpValue: 12, untuned: false, evidenceCount: 4),
            ],
            categoryCounts: [.basal: 100, .isf: 20, .csf: 40, .uam: 0],
            totalSamples: 160,
            basalSampleCountByHour: Array(repeating: 5, count: 24)
        )
        return TuningRecommendation(from: output, daysAnalyzed: 7, profileGlucoseUnit: .millimolesPerLiter, daysTuned: 6)
    }

    @Test("recommendation round-trips through JSON verbatim")
    func roundTrip() throws {
        let rec = sampleRecommendation()
        let data = try JSONEncoder().encode(rec)
        let decoded = try JSONDecoder().decode(TuningRecommendation.self, from: data)
        #expect(decoded == rec)
        #expect(decoded.categoryCounts[.basal] == 100)
        #expect(decoded.profileGlucoseUnit == .millimolesPerLiter)
        #expect(decoded.daysTuned == 6)
        #expect(decoded.sensitivitySchedule.count == 2)
        #expect(decoded.carbRatioSchedule[1].startMinutes == 12 * 60)
    }

    @Test("recommendations saved before override accounting decode compatibly")
    func legacyDecode() throws {
        let rec = sampleRecommendation()
        let encoded = try JSONEncoder().encode(rec)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "excludedOverrideSamples")
        object.removeValue(forKey: "sensitivitySchedule")
        object.removeValue(forKey: "carbRatioSchedule")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TuningRecommendation.self, from: legacyData)
        #expect(decoded.excludedOverrideSamples == 0)
        #expect(decoded.totalSamples == rec.totalSamples)
        #expect(decoded.sensitivitySchedule.count == 1)
        #expect(decoded.sensitivitySchedule[0].parameter == decoded.sensitivity)
        #expect(decoded.carbRatioSchedule.count == 1)
    }

    @Test("diagnostics saved before hourly distributions decode compatibly")
    func legacyDiagnosticsDecode() throws {
        let distribution = HourlyValueDistribution(
            hour: 0,
            sampleCount: 10,
            p10: 90,
            p25: 100,
            median: 110,
            p75: 120,
            p90: 130
        )
        let diagnostics = RunDiagnostics(
            glucoseCount: 10,
            doseCount: 0,
            carbCount: 0,
            windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: 3_600),
            daySummaries: [],
            hourlyDeviation: [],
            meanAbsDeviationBefore: 4,
            meanAbsDeviationAfter: 3,
            hourlyGlucose: [distribution]
        )
        let encoded = try JSONEncoder().encode(diagnostics)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "hourlyGlucose")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RunDiagnostics.self, from: legacyData)
        #expect(decoded.hourlyGlucose == nil)
        #expect(decoded.meanAbsDeviationBefore == 4)
    }
}

@Suite("RunStore")
struct RunStoreTests {
    private func makeStore(maxRuns: Int = 50) -> RunStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("looptune-runs-\(UUID().uuidString)", isDirectory: true)
        return RunStore(directory: dir, maxRuns: maxRuns)
    }

    private func makeRun(createdAt: Date) -> SavedRun {
        let output = TuningOutput(
            tunedBasalHourly: Array(repeating: 1.0, count: 24),
            pumpBasalHourly: Array(repeating: 1.0, count: 24),
            untunedBasalHours: Array(repeating: false, count: 24),
            tunedISF: 50, pumpISF: 50, tunedCarbRatio: 10, pumpCarbRatio: 10,
            categoryCounts: [:], totalSamples: 10
        )
        let rec = TuningRecommendation(from: output, daysAnalyzed: 1)
        let diag = RunDiagnostics(glucoseCount: 288, doseCount: 5, carbCount: 2, windowStart: createdAt, windowEnd: createdAt, daySummaries: [], hourlyDeviation: [], meanAbsDeviationBefore: 4, meanAbsDeviationAfter: 3)
        return SavedRun(id: RunStore.makeID(createdAt: createdAt), createdAt: createdAt, siteHost: "site", days: 1, insulinType: .novolog, recommendation: rec, diagnostics: diag)
    }

    @Test("saves and lists runs newest-first")
    func saveAndList() {
        let store = makeStore()
        let older = makeRun(createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = makeRun(createdAt: Date(timeIntervalSince1970: 1_700_100_000))
        store.save(older)
        store.save(newer)
        let all = store.loadAll()
        #expect(all.count == 2)
        #expect(all.first?.id == newer.id)   // newest first
        #expect(all.last?.id == older.id)
    }

    @Test("round-trips a full run with diagnostics")
    func roundTrip() {
        let store = makeStore()
        let run = makeRun(createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        store.save(run)
        let loaded = store.loadAll().first
        #expect(loaded == run)
        #expect(loaded?.diagnostics.glucoseCount == 288)
    }

    @Test("enforces the run limit, keeping the newest")
    func limit() {
        let store = makeStore(maxRuns: 3)
        for i in 0..<6 {
            store.save(makeRun(createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 1000)))
        }
        let all = store.loadAll()
        #expect(all.count == 3)
        // The three kept are the newest by creation time.
        #expect(all.map(\.createdAt).sorted().first! == Date(timeIntervalSince1970: 1_700_000_000 + 3000))
    }

    @Test("delete removes a run")
    func delete() {
        let store = makeStore()
        let run = makeRun(createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        store.save(run)
        store.delete(id: run.id)
        #expect(store.loadAll().isEmpty)
    }

    @Test("rejects path-like run IDs")
    func rejectsUnsafeID() {
        let store = makeStore()
        var run = makeRun(createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        run.id = "../outside"
        #expect(!store.save(run))
        #expect(!store.delete(id: "../outside"))
        #expect(store.loadAll().isEmpty)
    }

    @Test("a zero or negative limit retains no runs")
    func nonPositiveLimit() {
        for limit in [0, -5] {
            let store = makeStore(maxRuns: limit)
            #expect(store.save(makeRun(createdAt: Date(timeIntervalSince1970: 1_700_000_000))))
            #expect(store.loadAll().isEmpty)
        }
    }

    @Test("saved health-data files are owner-only")
    func privatePermissions() throws {
        let store = makeStore()
        let run = makeRun(createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(store.save(run))
        let file = store.directory.appendingPathComponent(run.id).appendingPathExtension("json")
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}

@Suite("DiagnosticsBuilder")
struct DiagnosticsBuilderTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func profile(basal: Double) throws -> TherapyProfile {
        TherapyProfile(
            basalSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: basal)]),
            sensitivitySchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 50)]),
            carbRatioSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 10)]),
            targetSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 100...110)]),
            timeZone: TimeZone(identifier: "UTC")!,
            glucoseUnit: .milligramsPerDeciliter,
            insulinType: .novolog
        )
    }

    @Test("day summaries aggregate glucose, boluses, and carbs per day")
    func daySummaries() throws {
        let profile = try profile(basal: 1.0)
        // One UTC day of glucose plus a bolus and a meal.
        let glucose = (0..<288).map { i in
            GlucoseSample(date: base.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: 120)
        }
        let doses = [DoseRecord(kind: .bolus(units: 3.0), startDate: base.addingTimeInterval(3600), endDate: base.addingTimeInterval(3600))]
        let carbs = [CarbRecord(date: base.addingTimeInterval(3600), grams: 40)]
        let inputs = TuningInputs(profile: profile, glucose: glucose, doses: doses, carbs: carbs, analysisStart: base, analysisEnd: glucose.last!.date)

        let summaries = DiagnosticsBuilder.daySummaries(inputs: inputs, timeZone: profile.timeZone)
        #expect(!summaries.isEmpty)
        let total = summaries.reduce(0) { $0 + $1.glucoseCount }
        #expect(total == 288)
        #expect(summaries.reduce(0) { $0 + $1.bolusCount } == 1)
        #expect(abs(summaries.reduce(0) { $0 + $1.totalBolusInsulin } - 3.0) < 1e-9)
        #expect(summaries.reduce(0) { $0 + $1.carbCount } == 1)
        // Flat 120 mg/dL → 100% in range.
        #expect(summaries.first?.timeInRangePercent == 100)
    }

    @Test("build produces before/after deviation stats and per-hour rows")
    func buildDiagnostics() async throws {
        let profile = try profile(basal: 1.0)
        let glucose = (0..<288).map { i in
            GlucoseSample(date: base.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: 110 + Double(i % 20))
        }
        let inputs = TuningInputs(profile: profile, glucose: glucose, doses: [], carbs: [], analysisStart: base, analysisEnd: glucose.last!.date)
        let rec = try TuningPipeline().run(inputs: inputs, configuration: TuningConfiguration(days: 1))
        let diag = await DiagnosticsBuilder().build(inputs: inputs, recommendation: rec)

        #expect(diag.hourlyDeviation.count == 24)
        #expect(diag.glucoseCount == 288)
        #expect(diag.meanAbsDeviationBefore >= 0)
        #expect(diag.meanAbsDeviationAfter >= 0)
        #expect(diag.hourlyGlucose?.count == 24)
        #expect(diag.hourlyGlucose?.allSatisfy {
            $0.p10 <= $0.p25
                && $0.p25 <= $0.median
                && $0.median <= $0.p75
                && $0.p75 <= $0.p90
        } == true)
    }

    @Test("hourly charts use conventional interpolated percentiles")
    func hourlyDistributionPercentiles() throws {
        let midnight = Date(timeIntervalSince1970: 0)
        let values = [100.0, 110, 120, 130, 140].enumerated().map { index, value in
            (
                date: midnight.addingTimeInterval(Double(index) * 60),
                value: value
            )
        }
        let row = try #require(
            DiagnosticsBuilder.hourlyDistribution(
                values,
                timeZone: TimeZone(secondsFromGMT: 0)!
            ).first
        )

        #expect(row.hour == 0)
        #expect(row.sampleCount == 5)
        #expect(row.p10 == 104)
        #expect(row.p25 == 110)
        #expect(row.median == 120)
        #expect(row.p75 == 130)
        #expect(row.p90 == 136)
    }

    @Test("diagnostics exclude insulin-needs override intervals")
    func diagnosticsExcludeOverrides() async throws {
        let profile = try profile(basal: 1.0)
        let glucose = (0..<40).map { index in
            GlucoseSample(
                date: base.addingTimeInterval(Double(index) * 300),
                milligramsPerDeciliter: 120 + Double(index)
            )
        }
        let override = OverridePeriod(
            startDate: base,
            endDate: base.addingTimeInterval(15 * 300),
            insulinNeedsScaleFactor: 1.5
        )
        let inputs = TuningInputs(
            profile: profile,
            glucose: glucose,
            doses: [],
            carbs: [],
            overrides: [override],
            analysisStart: base,
            analysisEnd: glucose.last!.date
        )
        let rec = try TuningPipeline().run(
            inputs: inputs,
            configuration: TuningConfiguration(days: 1)
        )
        let diagnostics = await DiagnosticsBuilder().build(inputs: inputs, recommendation: rec)
        #expect(diagnostics.hourlyDeviation.reduce(0) { $0 + $1.sampleCount } == rec.totalSamples)
    }
}
