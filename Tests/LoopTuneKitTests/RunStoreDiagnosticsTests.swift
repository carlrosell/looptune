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
            tunedISF: 48, pumpISF: 50,
            tunedCarbRatio: 9.5, pumpCarbRatio: 10,
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
    }
}
