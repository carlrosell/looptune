import Testing
import Foundation
@testable import LoopTuneKit

/// A historical profile can lie outside the limits anchored to the current
/// pump. Blocks without usable evidence must still return values inside those
/// limits, and must say they were not tuned.
@Suite("No-evidence pump-relative caps")
struct NoEvidenceCapTests {
    // 2023-11-13 00:00 UTC.
    private let base = Date(timeIntervalSince1970: 1_699_833_600)
    private let utc = TimeZone(identifier: "UTC")!

    // Default caps against pump ISF 40 and pump CR 10.
    private let maxISF = 40 / 0.7
    private let minISF = 40 / 1.2
    private let maxCR = 10 * 1.2
    private let minCR = 10 * 0.7

    private func profile(isf: Double, cr: Double, activeFrom: Date? = nil) throws -> TherapyProfile {
        TherapyProfile(
            basalSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 1.0)]),
            sensitivitySchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: isf)]),
            carbRatioSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: cr)]),
            targetSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 100...110)]),
            timeZone: utc,
            glucoseUnit: .milligramsPerDeciliter,
            activeFrom: activeFrom,
            insulinType: .novolog
        )
    }

    private func isfSamples(count: Int, deviation: Double, bgi: Double) -> [CategorizedSample] {
        (0..<count).map { index in
            CategorizedSample(
                sample: DeviationSample(
                    date: base.addingTimeInterval(Double(index) * 300),
                    glucose: 150,
                    averageDelta: 0,
                    insulinEffect: bgi,
                    deviation: deviation,
                    insulinOnBoard: 1,
                    carbsOnBoard: 0
                ),
                category: .isf,
                scheduledBasal: 1,
                scheduledISF: 100
            )
        }
    }

    @Test("scalar ISF tuner caps a historical value on every untuned return")
    func scalarSensitivity() {
        let tuner = SensitivityTuner()

        // No samples.
        let empty = tuner.tuneWithEvidence(samples: [], currentISF: 100, pumpISF: 40)
        #expect(empty.value == maxISF)
        #expect(empty.untuned)
        #expect(empty.usableSampleCount == 0)
        #expect(tuner.tune(samples: [], currentISF: 100, pumpISF: 40) == maxISF)

        // Fewer than the minimum usable ratios.
        let sparse = tuner.tuneWithEvidence(
            samples: isfSamples(count: 9, deviation: 1, bgi: -4),
            currentISF: 100,
            pumpISF: 40
        )
        #expect(sparse.value == maxISF)
        #expect(sparse.untuned)
        #expect(sparse.usableSampleCount == 9)

        // Enough ratios, but the computed ISF is rejected as non-positive.
        let rejected = tuner.tuneWithEvidence(
            samples: isfSamples(count: 20, deviation: 3, bgi: -2),
            currentISF: 10,
            pumpISF: 40
        )
        #expect(rejected.value == minISF)
        #expect(rejected.untuned)
        #expect(rejected.usableSampleCount == 20)

        // An unusable current value falls back to the pump baseline.
        let invalid = tuner.tuneWithEvidence(samples: [], currentISF: .nan, pumpISF: 40)
        #expect(invalid.value == 40)
        #expect(invalid.untuned)

        // A current value already inside the limits carries forward unchanged.
        #expect(tuner.tune(samples: [], currentISF: 45, pumpISF: 40) == 45)
    }

    @Test("scalar CR tuner caps a historical value on every untuned return")
    func scalarCarbRatio() {
        let tuner = CarbRatioTuner()

        // No meal carbs.
        let empty = tuner.tuneWithEvidence(
            mealDeviations: 0,
            totalMealCarbs: 0,
            replayISF: 100,
            targetISF: 100,
            currentCR: 30,
            pumpCR: 10
        )
        #expect(empty.value == maxCR)
        #expect(empty.untuned)
        #expect(tuner.tune(
            samples: [],
            totalMealCarbs: 0,
            replayISF: 100,
            targetISF: 100,
            currentCR: 30,
            pumpCR: 10
        ) == maxCR)

        // The residual makes carb sensitivity non-positive.
        let rejected = tuner.tuneWithEvidence(
            mealDeviations: -1_000,
            totalMealCarbs: 10,
            replayISF: 30,
            targetISF: 30,
            currentCR: 3,
            pumpCR: 10
        )
        #expect(rejected.value == minCR)
        #expect(rejected.untuned)

        // An unusable current value falls back to the pump baseline.
        let invalid = tuner.tuneWithEvidence(
            mealDeviations: 0,
            totalMealCarbs: 0,
            replayISF: 100,
            targetISF: 100,
            currentCR: 0,
            pumpCR: 10
        )
        #expect(invalid.value == 10)
        #expect(invalid.untuned)

        // A current value already inside the limits carries forward unchanged.
        #expect(tuner.tune(
            samples: [],
            totalMealCarbs: 0,
            replayISF: 100,
            targetISF: 100,
            currentCR: 11,
            pumpCR: 10
        ) == 11)
    }

    @Test("schedule tuners cap historical blocks that have no eligible evidence")
    func scheduleTuners() throws {
        let historical = try profile(isf: 100, cr: 30)
        let pump = try profile(isf: 40, cr: 10)

        let sensitivity = SensitivityTuner().tuneSchedule(
            samples: [],
            currentSchedule: historical.sensitivitySchedule,
            pumpSchedule: pump.sensitivitySchedule,
            timeZone: utc
        )
        #expect(sensitivity.count == 4)
        #expect(sensitivity.allSatisfy { $0.tunedValue == maxISF && $0.pumpValue == 40 })
        #expect(sensitivity.allSatisfy { $0.untuned && $0.evidenceCount == 0 })

        let carbRatio = CarbRatioTuner().tuneSchedule(
            samples: [],
            eligibleCarbs: [],
            attributionCarbs: [],
            currentProfile: historical,
            pumpSchedule: pump.carbRatioSchedule,
            tunedSensitivity: sensitivity
        )
        #expect(carbRatio.count == 1)
        #expect(carbRatio[0].tunedValue == maxCR)
        #expect(carbRatio[0].pumpValue == 10)
        #expect(carbRatio[0].untuned)
        #expect(carbRatio[0].evidenceCount == 0)
    }

    @Test("final recommendation keeps untuned historical blocks inside pump-relative caps")
    func finalRecommendation() throws {
        let historical = try profile(isf: 100, cr: 30)
        let pump = try profile(isf: 40, cr: 10)

        let output = try LoopTuner().tune(
            deviations: [],
            carbs: [],
            currentProfile: historical,
            pumpProfile: pump,
            analysisStart: base,
            analysisEnd: base.addingTimeInterval(86_400)
        )
        let recommendation = try TuningRecommendation(from: output, daysAnalyzed: 1)

        #expect(recommendation.sensitivitySchedule.count == 4)
        for block in recommendation.sensitivitySchedule {
            #expect(block.parameter.pumpValue == 40)
            #expect(block.parameter.recommendedValue == maxISF)
            #expect(block.untuned)
            #expect(block.evidenceDescription("samples") == "no data")
        }
        #expect(recommendation.sensitivity.recommendedValue <= maxISF + 1e-9)

        #expect(recommendation.carbRatioSchedule.count == 1)
        let carbRatio = recommendation.carbRatioSchedule[0]
        #expect(carbRatio.parameter.pumpValue == 10)
        #expect(carbRatio.parameter.recommendedValue == maxCR)
        #expect(carbRatio.untuned)
        #expect(carbRatio.evidenceDescription("meals") == "no data")
        #expect(recommendation.carbRatio.recommendedValue == maxCR)
    }

    @Test("historical-profile pipeline returns capped ISF and CR without block evidence")
    func historicalPipeline() throws {
        // The analysis covers two past days on ISF 100 / CR 30. The current
        // pump profile, ISF 40 / CR 10, was applied after the window. Flat
        // glucose with no insulin or carbs yields basal samples only.
        let old = try profile(isf: 100, cr: 30, activeFrom: base.addingTimeInterval(-86_400))
        let current = try profile(isf: 40, cr: 10, activeFrom: base.addingTimeInterval(3 * 86_400))
        let glucose = (0..<(2 * 288)).map { index in
            GlucoseSample(
                date: base.addingTimeInterval(Double(index) * 300),
                milligramsPerDeciliter: 115
            )
        }

        let recommendation = try TuningPipeline().run(
            inputs: TuningInputs(
                profile: current,
                profileHistory: ProfileHistory(timeline: [old, current], current: current),
                glucose: glucose,
                doses: [],
                carbs: [],
                analysisStart: base,
                analysisEnd: glucose.last!.date
            ),
            configuration: TuningConfiguration(days: 2)
        )

        #expect(recommendation.daysTuned != nil)
        #expect(recommendation.settingsChanges.isEmpty)
        #expect(recommendation.sensitivitySchedule.count == 4)
        for block in recommendation.sensitivitySchedule {
            #expect(block.parameter.pumpValue == 40)
            #expect(block.parameter.recommendedValue >= minISF - 0.0005)
            #expect(block.parameter.recommendedValue <= maxISF + 0.0005)
            #expect(block.untuned)
            #expect(block.evidenceCount == 0)
        }
        #expect(recommendation.carbRatioSchedule.count == 1)
        let carbRatio = recommendation.carbRatioSchedule[0]
        #expect(carbRatio.parameter.pumpValue == 10)
        #expect(carbRatio.parameter.recommendedValue >= minCR - 0.0005)
        #expect(carbRatio.parameter.recommendedValue <= maxCR + 0.0005)
        #expect(carbRatio.untuned)
        #expect(carbRatio.evidenceCount == 0)
    }
}
