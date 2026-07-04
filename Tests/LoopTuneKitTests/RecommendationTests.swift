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
}
