import Testing
import Foundation
@testable import LoopTuneKit

@Suite("Guardrails + change tiers")
struct GuardrailTests {
    @Test("clamps ISF to absolute limits and flags status")
    func isfClamp() {
        // Within recommended.
        let ok = LoopGuardrails.clamp(50, to: LoopGuardrails.sensitivity)
        #expect(ok.value == 50 && ok.status == .ok)
        // Outside recommended but within absolute.
        let outside = LoopGuardrails.clamp(450, to: LoopGuardrails.sensitivity)
        #expect(outside.value == 450 && outside.status == .outsideRecommended)
        // Beyond absolute → clamped.
        let limited = LoopGuardrails.clamp(600, to: LoopGuardrails.sensitivity)
        #expect(limited.value == 500 && limited.status == .atLimit)
    }

    @Test("carb ratio clamps to absolute 2…150")
    func crClamp() {
        #expect(LoopGuardrails.clamp(1, to: LoopGuardrails.carbRatio).value == 2)
        #expect(LoopGuardrails.clamp(200, to: LoopGuardrails.carbRatio).value == 150)
    }

    @Test("change tiers follow autotune thresholds")
    func tiers() {
        #expect(ChangeTier.classify(pump: 100, tuned: 105) == .minimal)   // 5%
        #expect(ChangeTier.classify(pump: 100, tuned: 112) == .notable)   // 12%
        #expect(ChangeTier.classify(pump: 100, tuned: 125) == .large)     // +25%
        #expect(ChangeTier.classify(pump: 100, tuned: 65) == .large)      // -35%
        #expect(ChangeTier.classify(pump: 100, tuned: 88) == .notable)    // -12%
    }

    @Test("basal rates round to the pump increment")
    func basalRounding() {
        func hourRec(_ rate: Double) -> BasalHourRecommendation {
            BasalHourRecommendation(hour: 0, pumpRate: 1.0, rawTunedRate: rate, untuned: false)
        }
        // 0.194 → 0.20 at Loop's 0.05 steps.
        #expect(hourRec(0.194).roundedRate() == 0.2)
        #expect(hourRec(1.021).roundedRate() == 1.0)
        #expect(hourRec(1.097).roundedRate() == 1.1)
        // Half-step rounds away from zero: 0.125 → 0.15.
        #expect(hourRec(0.125).roundedRate() == 0.15)
        // Exact multiples pass through without FP dust.
        #expect(hourRec(0.85).roundedRate() == 0.85)
        // A tiny positive recommendation never rounds down to zero…
        #expect(hourRec(0.06).roundedRate(toIncrement: 0.25) == 0.25)
        // …and other increments work (Medtronic 0.025).
        #expect(hourRec(0.194).roundedRate(toIncrement: 0.025) == 0.2)
        #expect(hourRec(0.21).roundedRate(toIncrement: 0.025) == 0.2)
    }

    @Test("loop basal schedule collapses to change points like Loop's entry screen")
    func loopScheduleCollapse() {
        // Rounded rates: 0.2 (00–05), 0.25 (06–11), 0.3 (12–15), 0.5 (16–17), 0.3 (18–23)
        // → exactly the 5 entries from Loop's Basaldoser screen.
        var hourly = [Double]()
        hourly += Array(repeating: 0.21, count: 6)   // rounds to 0.2
        hourly += Array(repeating: 0.24, count: 6)   // rounds to 0.25
        hourly += Array(repeating: 0.31, count: 4)   // rounds to 0.3
        hourly += Array(repeating: 0.49, count: 2)   // rounds to 0.5
        hourly += Array(repeating: 0.29, count: 6)   // rounds to 0.3
        let output = TuningOutput(
            tunedBasalHourly: hourly,
            pumpBasalHourly: Array(repeating: 0.3, count: 24),
            untunedBasalHours: Array(repeating: false, count: 24),
            tunedISF: 50, pumpISF: 50, tunedCarbRatio: 10, pumpCarbRatio: 10,
            categoryCounts: [:], totalSamples: 100
        )
        let rec = TuningRecommendation(from: output, daysAnalyzed: 1)
        let entries = rec.loopBasalSchedule()
        #expect(entries.count == 5)
        #expect(entries[0] == LoopBasalEntry(startMinutes: 0, rate: 0.2))
        #expect(entries[1] == LoopBasalEntry(startMinutes: 6 * 60, rate: 0.25))
        #expect(entries[2] == LoopBasalEntry(startMinutes: 12 * 60, rate: 0.3))
        #expect(entries[3] == LoopBasalEntry(startMinutes: 16 * 60, rate: 0.5))
        #expect(entries[4] == LoopBasalEntry(startMinutes: 18 * 60, rate: 0.3))
        #expect(entries[1].timeString == "06:00")
        // A flat schedule collapses to a single midnight entry.
        let flat = TuningOutput(
            tunedBasalHourly: Array(repeating: 1.0, count: 24),
            pumpBasalHourly: Array(repeating: 1.0, count: 24),
            untunedBasalHours: Array(repeating: false, count: 24),
            tunedISF: 50, pumpISF: 50, tunedCarbRatio: 10, pumpCarbRatio: 10,
            categoryCounts: [:], totalSamples: 100
        )
        let flatEntries = TuningRecommendation(from: flat, daysAnalyzed: 1).loopBasalSchedule()
        #expect(flatEntries == [LoopBasalEntry(startMinutes: 0, rate: 1.0)])
    }

    @Test("report and JSON include the rounded basal column")
    func roundedInOutputs() throws {
        let output = TuningOutput(
            tunedBasalHourly: Array(repeating: 1.021, count: 24),
            pumpBasalHourly: Array(repeating: 1.0, count: 24),
            untunedBasalHours: Array(repeating: false, count: 24),
            tunedISF: 48.0, pumpISF: 50.0,
            tunedCarbRatio: 10.0, pumpCarbRatio: 10.0,
            categoryCounts: [:], totalSamples: 100
        )
        let rec = TuningRecommendation(from: output, daysAnalyzed: 1)
        let text = TuningReport.render(rec)
        #expect(text.contains("Rounded"))
        #expect(text.contains("1.00"))
        let json = try RecommendationJSON.encode(rec)
        #expect(json.contains("recommendedRounded"))
        #expect(json.contains("basalIncrement"))
        #expect(json.contains("sensitivitySchedule"))
        #expect(json.contains("carbRatioSchedule"))
        #expect(json.contains("NOT medical advice"))
        // 24 × 1.00 rounded.
        #expect(abs(rec.roundedDailyBasal() - 24.0) < 1e-9)
    }

    @Test("ISF converts to mmol/L/U for display; carb ratio and % change do not")
    func mmolDisplay() {
        let isf = ParameterRecommendation(
            name: "Insulin Sensitivity", unit: "mg/dL/U",
            pumpValue: 50, rawTunedValue: 45, bounds: LoopGuardrails.sensitivity, isGlucoseDenominated: true
        )
        // 45 mg/dL/U ÷ 18.0156 ≈ 2.498 mmol/L/U
        #expect(abs(isf.recommendedValue(in: .millimolesPerLiter) - 2.498) < 0.01)
        #expect(isf.recommendedValue(in: .milligramsPerDeciliter) == 45)
        #expect(isf.unitLabel(in: .millimolesPerLiter) == "mmol/L/U")
        #expect(isf.unitLabel(in: .milligramsPerDeciliter) == "mg/dL/U")

        let cr = ParameterRecommendation(
            name: "Carb Ratio", unit: "g/U",
            pumpValue: 10, rawTunedValue: 9, bounds: LoopGuardrails.carbRatio, isGlucoseDenominated: false
        )
        // Carb ratio is never converted.
        #expect(cr.recommendedValue(in: .millimolesPerLiter) == 9)
        #expect(cr.unitLabel(in: .millimolesPerLiter) == "g/U")
        // Percent change is unit-invariant.
        #expect(abs(isf.percentChange - (-10)) < 1e-9)
    }

    @Test("time-of-day summaries match the guardrail-clamped schedule")
    func scheduleSummaryUsesClampedEntries() throws {
        let output = TuningOutput(
            tunedBasalHourly: Array(repeating: 1.0, count: 24),
            pumpBasalHourly: Array(repeating: 1.0, count: 24),
            untunedBasalHours: Array(repeating: false, count: 24),
            sensitivitySchedule: [
                ScheduleTuningOutput(secondsSinceMidnight: 0, tunedValue: 600, pumpValue: 50, untuned: false, evidenceCount: 12),
                ScheduleTuningOutput(secondsSinceMidnight: 12 * 3600, tunedValue: 600, pumpValue: 60, untuned: false, evidenceCount: 14),
            ],
            carbRatioSchedule: [
                ScheduleTuningOutput(secondsSinceMidnight: 0, tunedValue: 10, pumpValue: 10, untuned: false),
            ],
            categoryCounts: [.isf: 26],
            totalSamples: 26
        )
        let recommendation = TuningRecommendation(from: output, daysAnalyzed: 1)

        #expect(recommendation.sensitivity.rawTunedValue == 600)
        #expect(recommendation.sensitivity.recommendedValue == 500)
        #expect(recommendation.sensitivity.guardrailStatus == .atLimit)
        #expect(recommendation.sensitivitySchedule.allSatisfy {
            $0.parameter.recommendedValue == 500 && $0.parameter.guardrailStatus == .atLimit
        })
        #expect(TuningReport.render(recommendation).contains("Insulin Sensitivity schedule"))
        #expect(try RecommendationJSON.encode(recommendation).contains("\"time\" : \"12:00\""))
    }
}

@Suite("End-to-end pipeline")
struct PipelineIntegrationTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func profile() throws -> TherapyProfile {
        TherapyProfile(
            basalSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 1.0)]),
            sensitivitySchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 50)]),
            carbRatioSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 10)]),
            targetSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 100...110)]),
            timeZone: TimeZone(identifier: "UTC")!,
            glucoseUnit: .milligramsPerDeciliter,
            insulinType: .novolog
        )
    }

    @Test("configuration keeps days inside the documented 1...30 range after mutation")
    func configurationClampsMutations() {
        var configuration = TuningConfiguration(days: 7)
        configuration.days = 0
        #expect(configuration.days == 1)
        configuration.days = 100
        #expect(configuration.days == 30)
    }

    @Test("under-basaled data recommends higher basal")
    func underBasaledRaisesBasal() throws {
        // 24h of glucose drifting up ~1 mg/dL per 5 min with only scheduled basal
        // delivered (no temps, no carbs): the person needs more basal than 1 U/hr.
        let count = 288
        let glucose = (0..<count).map { i in
            GlucoseSample(date: base.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: 110 + Double(i % 30))
        }
        let inputs = TuningInputs(
            profile: try profile(),
            glucose: glucose,
            doses: [],
            carbs: [],
            analysisStart: base,
            analysisEnd: glucose.last!.date
        )
        let rec = try TuningPipeline().run(inputs: inputs, configuration: TuningConfiguration(days: 1))
        // Persistent upward drift with no insulin → basal should not decrease
        // overall, and the recommendation is well-formed.
        #expect(rec.basalHours.count == 24)
        #expect(rec.tunedDailyBasal >= rec.pumpDailyBasal - 1e-6)
        #expect(rec.sensitivity.recommendedValue > 0)
        #expect(rec.carbRatio.recommendedValue > 0)
    }

    @Test("recommendation renders to text and JSON without error")
    func rendering() throws {
        let count = 60
        let glucose = (0..<count).map { i in
            GlucoseSample(date: base.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: 120)
        }
        let inputs = TuningInputs(profile: try profile(), glucose: glucose, doses: [], carbs: [], analysisStart: base, analysisEnd: glucose.last!.date)
        let rec = try TuningPipeline().run(inputs: inputs, configuration: TuningConfiguration(days: 1))

        let text = TuningReport.render(rec)
        #expect(text.contains("LoopTune recommendations"))
        #expect(text.contains("medical"))
        #expect(text.contains("Insulin Sensitivity"))

        let json = try RecommendationJSON.encode(rec)
        #expect(json.contains("\"sensitivity\""))
        #expect(json.contains("\"basal\""))

        // Rendering in mmol/L labels the units accordingly.
        let mmolText = TuningReport.render(rec, displayUnit: .millimolesPerLiter)
        #expect(mmolText.contains("mmol/L"))
        // (JSONEncoder escapes the slash as "mmol\/L", so match on "mmol".)
        let mmolJSON = try RecommendationJSON.encode(rec, displayUnit: .millimolesPerLiter)
        #expect(mmolJSON.contains("mmol"))
    }

    @Test("recommendation carries the site's glucose unit as the display default")
    func profileUnitDefault() throws {
        var profile = try profile()
        profile.glucoseUnit = .millimolesPerLiter
        let count = 60
        let glucose = (0..<count).map { i in
            GlucoseSample(date: base.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: 120)
        }
        let inputs = TuningInputs(profile: profile, glucose: glucose, doses: [], carbs: [], analysisStart: base, analysisEnd: glucose.last!.date)
        let rec = try TuningPipeline().run(inputs: inputs, configuration: TuningConfiguration(days: 1))
        #expect(rec.profileGlucoseUnit == .millimolesPerLiter)
        // Auto-render uses the site unit.
        #expect(TuningReport.render(rec).contains("mmol/L"))
    }

    @Test("stable in-range flat data recommends little change")
    func flatDataMinimalChange() throws {
        // Flat glucose at target with matched basal: tuning should barely move.
        let count = 288
        let glucose = (0..<count).map { i in
            GlucoseSample(date: base.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: 105)
        }
        let inputs = TuningInputs(profile: try profile(), glucose: glucose, doses: [], carbs: [], analysisStart: base, analysisEnd: glucose.last!.date)
        let rec = try TuningPipeline().run(inputs: inputs, configuration: TuningConfiguration(days: 1))
        // ISF has < 10 ISF-categorized points here (flat, no insulin activity) so
        // it stays put; basal daily total should be close to pump.
        #expect(abs(rec.tunedDailyBasal - rec.pumpDailyBasal) < rec.pumpDailyBasal * 0.35)
    }

    @Test("pipeline rejects an invalid window and windows without enough usable evidence")
    func rejectsInvalidOrSparseWindows() throws {
        let profile = try profile()
        let two = [
            GlucoseSample(date: base, milligramsPerDeciliter: 120),
            GlucoseSample(date: base.addingTimeInterval(300), milligramsPerDeciliter: 121),
        ]
        let pipeline = TuningPipeline()
        #expect(throws: TuningPipeline.PipelineError.invalidAnalysisWindow) {
            _ = try pipeline.run(
                inputs: TuningInputs(
                    profile: profile,
                    glucose: two,
                    doses: [],
                    carbs: [],
                    analysisStart: base,
                    analysisEnd: base
                ),
                configuration: TuningConfiguration(days: 1)
            )
        }
        #expect(throws: TuningPipeline.PipelineError.insufficientUsableData(minimum: 12, actual: 1)) {
            _ = try pipeline.run(
                inputs: TuningInputs(
                    profile: profile,
                    glucose: two,
                    doses: [],
                    carbs: [],
                    analysisStart: base,
                    analysisEnd: two.last!.date
                ),
                configuration: TuningConfiguration(days: 1)
            )
        }
    }

    @Test("insulin-needs overrides exclude samples and are reported")
    func excludesOverrideSamples() throws {
        let profile = try profile()
        let glucose = (0..<60).map { index in
            GlucoseSample(
                date: base.addingTimeInterval(Double(index) * 300),
                milligramsPerDeciliter: 120 + Double(index)
            )
        }
        let override = OverridePeriod(
            startDate: base,
            endDate: base.addingTimeInterval(20 * 300),
            insulinNeedsScaleFactor: 1.5
        )
        let rec = try TuningPipeline().run(
            inputs: TuningInputs(
                profile: profile,
                glucose: glucose,
                doses: [],
                carbs: [],
                overrides: [override],
                analysisStart: base,
                analysisEnd: glucose.last!.date
            ),
            configuration: TuningConfiguration(days: 1)
        )
        #expect(rec.excludedOverrideSamples == 19)
        #expect(rec.totalSamples + rec.excludedOverrideSamples == 59)
        #expect(TuningReport.render(rec).contains("19 samples during insulin-needs overrides"))
        #expect(try RecommendationJSON.encode(rec).contains("\"excludedOverrideSamples\" : 19"))
    }

    @Test("an override covering all evidence prevents a recommendation")
    func allEvidenceOverridden() throws {
        let profile = try profile()
        let glucose = (0..<20).map { index in
            GlucoseSample(
                date: base.addingTimeInterval(Double(index) * 300),
                milligramsPerDeciliter: 120 + Double(index)
            )
        }
        let override = OverridePeriod(
            startDate: base,
            endDate: nil,
            insulinNeedsScaleFactor: 0.5
        )
        #expect(throws: TuningPipeline.PipelineError.insufficientUsableData(minimum: 12, actual: 0)) {
            _ = try TuningPipeline().run(
                inputs: TuningInputs(
                    profile: profile,
                    glucose: glucose,
                    doses: [],
                    carbs: [],
                    overrides: [override],
                    analysisStart: base,
                    analysisEnd: glucose.last!.date
                ),
                configuration: TuningConfiguration(days: 1)
            )
        }
    }

    @Test("offline pipeline rejects non-finite domain input before replay")
    func rejectsNonFiniteOfflineInput() throws {
        let glucose = (0..<20).map { index in
            GlucoseSample(
                date: base.addingTimeInterval(Double(index) * 300),
                milligramsPerDeciliter: index == 8 ? .nan : 120
            )
        }
        #expect(throws: TuningPipeline.PipelineError.invalidInput("glucose")) {
            _ = try TuningPipeline().run(
                inputs: TuningInputs(
                    profile: try profile(),
                    glucose: glucose,
                    doses: [],
                    carbs: [],
                    analysisStart: base,
                    analysisEnd: glucose.last!.date
                ),
                configuration: TuningConfiguration(days: 1)
            )
        }
    }
}
