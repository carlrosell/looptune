import Testing
import Foundation
@testable import LoopTuneKit

@Suite("TuningMath")
struct TuningMathTests {
    @Test("median matches oref0's percentile (index = n·p)")
    func median() {
        // oref0's percentile: index = n·p. For [1,2,3], p=0.5 → index 1.5 → 2.5.
        #expect(TuningMath.median([3, 1, 2]) == 2.5)
        // For [1,2,3,4], index = 2 → arr[2] = 3.
        #expect(TuningMath.median([1, 2, 3, 4]) == 3.0)
        #expect(TuningMath.median([5]) == 5)
    }

    @Test("percentile interpolates linearly (oref0 semantics)")
    func percentile() {
        let sorted = [0.0, 10.0, 20.0, 30.0]
        #expect(TuningMath.percentile(sorted, 0.0) == 0)
        // index = 4·0.5 = 2 → arr[2] = 20.
        #expect(TuningMath.percentile(sorted, 0.5) == 20)
        // index = 4·0.25 = 1 → arr[1] = 10.
        #expect(TuningMath.percentile(sorted, 0.25) == 10)
    }

    @Test("clamp bounds values")
    func clamp() {
        #expect(TuningMath.clamp(5, 0, 10) == 5)
        #expect(TuningMath.clamp(-1, 0, 10) == 0)
        #expect(TuningMath.clamp(11, 0, 10) == 10)
    }
}

@Suite("Schedule helpers")
struct ScheduleHelperTests {
    @Test("hourly values sample each hour")
    func hourly() throws {
        let schedule = try DailySchedule(entries: [
            .init(secondsSinceMidnight: 0, value: 0.8),
            .init(secondsSinceMidnight: 6 * 3600, value: 1.0),
        ])
        let hourly = schedule.hourlyValues()
        #expect(hourly.count == 24)
        #expect(hourly[0] == 0.8)
        #expect(hourly[5] == 0.8)
        #expect(hourly[6] == 1.0)
        #expect(hourly[23] == 1.0)
    }

    @Test("time-weighted average weights by duration")
    func weightedAverage() throws {
        // 0.8 for 6h, then 1.0 for 18h.
        let schedule = try DailySchedule(entries: [
            .init(secondsSinceMidnight: 0, value: 0.8),
            .init(secondsSinceMidnight: 6 * 3600, value: 1.0),
        ])
        let expected = (0.8 * 6 + 1.0 * 18) / 24
        #expect(abs(schedule.timeWeightedAverage() - expected) < 1e-9)
    }

    @Test("schedule tuning output rejects invalid public schedules without trapping")
    func tuningOutputValidation() throws {
        let midnight = ScheduleTuningOutput(
            secondsSinceMidnight: 0,
            tunedValue: 10,
            pumpValue: 10,
            untuned: false
        )
        let late = ScheduleTuningOutput(
            secondsSinceMidnight: 60,
            tunedValue: 10,
            pumpValue: 10,
            untuned: false
        )
        let later = ScheduleTuningOutput(
            secondsSinceMidnight: 120,
            tunedValue: 10,
            pumpValue: 10,
            untuned: false
        )
        let outOfRange = ScheduleTuningOutput(
            secondsSinceMidnight: 86_400,
            tunedValue: 10,
            pumpValue: 10,
            untuned: false
        )
        let basal = Array(repeating: 1.0, count: 24)
        let untuned = Array(repeating: false, count: 24)

        #expect(throws: TuningOutput.InitializationError.emptySchedule(.sensitivity)) {
            try TuningOutput(
                tunedBasalHourly: basal,
                pumpBasalHourly: basal,
                untunedBasalHours: untuned,
                sensitivitySchedule: [],
                carbRatioSchedule: [midnight],
                categoryCounts: [:],
                totalSamples: 0
            )
        }
        #expect(throws: TuningOutput.InitializationError.missingMidnightEntry(.carbRatio, firstOffset: 60)) {
            try TuningOutput(
                tunedBasalHourly: basal,
                pumpBasalHourly: basal,
                untunedBasalHours: untuned,
                sensitivitySchedule: [midnight],
                carbRatioSchedule: [late],
                categoryCounts: [:],
                totalSamples: 0
            )
        }
        #expect(throws: TuningOutput.InitializationError.offsetOutOfRange(.sensitivity, offset: 86_400)) {
            try TuningOutput(
                tunedBasalHourly: basal,
                pumpBasalHourly: basal,
                untunedBasalHours: untuned,
                sensitivitySchedule: [midnight, outOfRange],
                carbRatioSchedule: [midnight],
                categoryCounts: [:],
                totalSamples: 0
            )
        }
        #expect(throws: TuningOutput.InitializationError.duplicateOffset(.carbRatio, offset: 0)) {
            try TuningOutput(
                tunedBasalHourly: basal,
                pumpBasalHourly: basal,
                untunedBasalHours: untuned,
                sensitivitySchedule: [midnight],
                carbRatioSchedule: [midnight, midnight],
                categoryCounts: [:],
                totalSamples: 0
            )
        }
        #expect(throws: TuningOutput.InitializationError.outOfOrderOffset(
            .sensitivity,
            previousOffset: 120,
            offset: 60
        )) {
            try TuningOutput(
                tunedBasalHourly: basal,
                pumpBasalHourly: basal,
                untunedBasalHours: untuned,
                sensitivitySchedule: [midnight, later, late],
                carbRatioSchedule: [midnight],
                categoryCounts: [:],
                totalSamples: 0
            )
        }
        _ = try TuningOutput(
            tunedBasalHourly: basal,
            pumpBasalHourly: basal,
            untunedBasalHours: untuned,
            sensitivitySchedule: [midnight],
            carbRatioSchedule: [midnight],
            categoryCounts: [:],
            totalSamples: 0
        )
    }
}

@Suite("Tuners")
struct TunerTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(_ offsetMinutes: Double, deviation: Double, bgi: Double = -1, iob: Double = 0, cob: Double = 0, glucose: Double = 150, avgDelta: Double = 0) -> DeviationSample {
        DeviationSample(
            date: base.addingTimeInterval(offsetMinutes * 60),
            glucose: glucose,
            averageDelta: avgDelta,
            insulinEffect: bgi,
            deviation: deviation,
            insulinOnBoard: iob,
            carbsOnBoard: cob
        )
    }

    @Test("ISF tuner leaves ISF unchanged below the data-point minimum")
    func isfMinData() {
        let tuner = SensitivityTuner()
        let samples = (0..<5).map { CategorizedSample(sample: sample(Double($0) * 5, deviation: 2), category: .isf, scheduledBasal: 1, scheduledISF: 50) }
        #expect(tuner.tune(samples: samples, currentISF: 50, pumpISF: 50) == 50)
    }

    @Test("ISF tuner lowers ISF when deviations are consistently positive")
    func isfLowersOnPositiveDeviations() {
        let tuner = SensitivityTuner()
        // A mild positive deviation vs a larger insulin effect keeps the ratio
        // in (0, 1): 1 + 1/(-4) = 0.75 → ISF moves down.
        let samples = (0..<20).map { CategorizedSample(sample: sample(Double($0) * 5, deviation: 1, bgi: -4), category: .isf, scheduledBasal: 1, scheduledISF: 50) }
        let newISF = tuner.tune(samples: samples, currentISF: 50, pumpISF: 50)
        #expect(newISF < 50)
        // Respects the inverted lower cap (pumpISF / autotuneMax).
        #expect(newISF >= 50 / 1.2)
    }

    @Test("ISF tuner keeps ISF unchanged when the computed value goes negative")
    func isfGuardsNegative() {
        let tuner = SensitivityTuner()
        // deviation magnitude exceeds BGI → ratio negative → keep current ISF.
        let samples = (0..<20).map { CategorizedSample(sample: sample(Double($0) * 5, deviation: 3, bgi: -2), category: .isf, scheduledBasal: 1, scheduledISF: 50) }
        #expect(tuner.tune(samples: samples, currentISF: 50, pumpISF: 50) == 50)
    }

    @Test("ISF minimum counts only finite samples with a nonzero insulin effect")
    func isfMinimumUsesUsableRatios() {
        let tuner = SensitivityTuner()
        var samples = (0..<9).map {
            CategorizedSample(
                sample: sample(Double($0) * 5, deviation: 1, bgi: 0),
                category: .isf,
                scheduledBasal: 1,
                scheduledISF: 50
            )
        }
        samples.append(CategorizedSample(
            sample: sample(45, deviation: 1, bgi: -4),
            category: .isf,
            scheduledBasal: 1,
            scheduledISF: 50
        ))
        #expect(tuner.tune(samples: samples, currentISF: 50, pumpISF: 50) == 50)
    }

    @Test("ISF schedule tunes configured time blocks independently")
    func isfScheduleByTimeOfDay() throws {
        let utc = TimeZone(identifier: "UTC")!
        let midnight = Date(timeIntervalSince1970: 1_699_833_600)
        let schedule = try DailySchedule(entries: [
            .init(secondsSinceMidnight: 0, value: 50.0),
            .init(secondsSinceMidnight: 8 * 3600, value: 60.0),
            .init(secondsSinceMidnight: 16 * 3600, value: 70.0),
        ])

        func entries(hour: Int, count: Int, deviation: Double, isf: Double) -> [CategorizedSample] {
            (0..<count).map { index in
                let datum = DeviationSample(
                    date: midnight.addingTimeInterval(Double(hour * 3600 + index * 300)),
                    glucose: 150,
                    averageDelta: 0,
                    insulinEffect: -4,
                    deviation: deviation,
                    insulinOnBoard: 1,
                    carbsOnBoard: 0
                )
                return CategorizedSample(
                    sample: datum,
                    category: .isf,
                    scheduledBasal: 1,
                    scheduledISF: isf
                )
            }
        }

        let samples = entries(hour: 1, count: 10, deviation: 1, isf: 50)
            + entries(hour: 10, count: 10, deviation: -1, isf: 60)
            + entries(hour: 18, count: 9, deviation: 1, isf: 70)
        let result = SensitivityTuner().tuneSchedule(
            samples: samples,
            currentSchedule: schedule,
            pumpSchedule: schedule,
            timeZone: utc
        )

        #expect(result.map(\.secondsSinceMidnight) == [0, 8 * 3600, 16 * 3600])
        #expect(result[0].tunedValue < 50)
        #expect(result[1].tunedValue > 60)
        #expect(result[2].tunedValue == 70)
        #expect(result.map(\.evidenceCount) == [10, 10, 9])
        #expect(result.map(\.untuned) == [false, false, true])
    }

    @Test("basal tuner raises prior hours when deviations are positive")
    func basalRaisesPriorHours() {
        // All deviations at hour 12 (UTC), positive → basal at hours 9,10,11 rise.
        let tuner = BasalTuner(timeZone: TimeZone(identifier: "UTC")!)
        let noon = Date(timeIntervalSince1970: 1_700_000_000)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let noonExact = cal.date(bySettingHour: 12, minute: 0, second: 0, of: noon)!
        let samples = (0..<6).map { i -> CategorizedSample in
            let s = DeviationSample(date: noonExact.addingTimeInterval(Double(i) * 300), glucose: 150, averageDelta: 2, insulinEffect: -1, deviation: 6, insulinOnBoard: 0, carbsOnBoard: 0)
            return CategorizedSample(sample: s, category: .basal, scheduledBasal: 1, scheduledISF: 50)
        }
        let current = Array(repeating: 1.0, count: 24)
        let result = tuner.tune(samples: samples, currentHourly: current, pumpHourly: current, isf: 50)
        #expect(result.hourlyRates[11] > 1.0)
        #expect(result.hourlyRates[10] > 1.0)
        #expect(result.hourlyRates[9] > 1.0)
        // Capped at pump * 1.2.
        #expect(result.hourlyRates.allSatisfy { $0 <= 1.2 + 1e-9 })
        // Noon evidence adjusts the three preceding basal hours, so coverage
        // must be attached to those hours rather than to 12:00.
        #expect(result.sampleCounts[9] == 6)
        #expect(result.sampleCounts[10] == 6)
        #expect(result.sampleCounts[11] == 6)
        #expect(result.sampleCounts[12] == 0)
    }

    @Test("basal smoothing cannot restore rates outside current pump-relative caps")
    func basalCapsAfterSmoothing() {
        let tuner = BasalTuner(timeZone: TimeZone(identifier: "UTC")!)
        let result = tuner.tune(
            samples: [],
            currentHourly: Array(repeating: 10.0, count: 24),
            pumpHourly: Array(repeating: 1.0, count: 24),
            isf: 50
        )
        #expect(result.hourlyRates.allSatisfy { $0 == 1.2 })
        #expect(result.untuned.allSatisfy { $0 })
    }

    @Test("carb ratio tuner lowers CR when carbs raise BG more than modeled")
    func crLowersOnMealDeviations() {
        let tuner = CarbRatioTuner()
        // Positive residual deviations during absorption: carbs were under-modeled.
        // csfReplay = 50/10 = 5; residual/g = 60/60 = 1 → csfTrue = 6 → CR = 50/6 ≈ 8.33.
        let samples = (0..<12).map { CategorizedSample(sample: sample(Double($0) * 5, deviation: 5), category: .csf, scheduledBasal: 1, scheduledISF: 50, mealCarbs: 40) }
        let newCR = tuner.tune(samples: samples, totalMealCarbs: 60, replayISF: 50, targetISF: 50, currentCR: 10, pumpCR: 10)
        #expect(newCR < 10)
        #expect(newCR >= 10 * 0.7)   // capped
    }

    @Test("carb ratio tuner raises CR when carbs raise BG less than modeled")
    func crRaisesOnNegativeResidual() {
        let tuner = CarbRatioTuner()
        let samples = (0..<12).map { CategorizedSample(sample: sample(Double($0) * 5, deviation: -2), category: .csf, scheduledBasal: 1, scheduledISF: 50, mealCarbs: 40) }
        let newCR = tuner.tune(samples: samples, totalMealCarbs: 60, replayISF: 50, targetISF: 50, currentCR: 10, pumpCR: 10)
        #expect(newCR > 10)
    }

    @Test("carb ratio tuner leaves CR unchanged with no meal data")
    func crUnchangedWithoutMeals() {
        let tuner = CarbRatioTuner()
        #expect(tuner.tune(samples: [], totalMealCarbs: 0, replayISF: 50, targetISF: 50, currentCR: 10, pumpCR: 10) == 10)
    }

    @Test("carb-ratio residuals stay with the time block active at the meal")
    func carbRatioScheduleByMealTime() throws {
        let utc = TimeZone(identifier: "UTC")!
        let midnight = Date(timeIntervalSince1970: 1_699_833_600)
        let carbRatio = try DailySchedule(entries: [
            .init(secondsSinceMidnight: 0, value: 10.0),
            .init(secondsSinceMidnight: 12 * 3600, value: 12.0),
        ])
        let profile = TherapyProfile(
            basalSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 1.0)]),
            sensitivitySchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 50.0)]),
            carbRatioSchedule: carbRatio,
            targetSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 100.0...110.0)]),
            timeZone: utc,
            glucoseUnit: .milligramsPerDeciliter
        )
        let breakfast = CarbRecord(date: midnight.addingTimeInterval(8 * 3600), grams: 40)
        let dinner = CarbRecord(date: midnight.addingTimeInterval(18 * 3600), grams: 60)

        func csf(hour: Int, deviation: Double) -> CategorizedSample {
            let datum = DeviationSample(
                date: midnight.addingTimeInterval(Double(hour * 3600)),
                glucose: 150,
                averageDelta: 0,
                insulinEffect: -1,
                deviation: deviation,
                insulinOnBoard: 2,
                carbsOnBoard: 20
            )
            return CategorizedSample(
                sample: datum,
                category: .csf,
                scheduledBasal: 1,
                scheduledISF: 50,
                mealCarbs: 20
            )
        }

        let result = CarbRatioTuner().tuneSchedule(
            // Breakfast is still absorbing after the noon CR boundary.
            samples: [csf(hour: 13, deviation: 20), csf(hour: 19, deviation: -20)],
            carbs: [breakfast, dinner],
            currentProfile: profile,
            pumpSchedule: carbRatio,
            tunedSensitivity: [ScheduleTuningOutput(
                secondsSinceMidnight: 0,
                tunedValue: 50,
                pumpValue: 50,
                untuned: false
            )]
        )

        #expect(result.map(\.secondsSinceMidnight) == [0, 12 * 3600])
        #expect(result[0].tunedValue < 10)
        #expect(result[1].tunedValue > 12)
        #expect(result.map(\.evidenceCount) == [1, 1])
        #expect(result.allSatisfy { !$0.untuned })

        let resultWithPreMealResidual = CarbRatioTuner().tuneSchedule(
            samples: [
                csf(hour: 6, deviation: 1_000),
                csf(hour: 13, deviation: 20),
                csf(hour: 19, deviation: -20),
            ],
            carbs: [breakfast, dinner],
            currentProfile: profile,
            pumpSchedule: carbRatio,
            tunedSensitivity: [ScheduleTuningOutput(
                secondsSinceMidnight: 0,
                tunedValue: 50,
                pumpValue: 50,
                untuned: false
            )]
        )
        #expect(resultWithPreMealResidual == result)
    }

    @Test("empty tuned sensitivity is handled safely during carb-ratio tuning")
    func carbRatioScheduleWithEmptySensitivity() throws {
        let utc = TimeZone(identifier: "UTC")!
        let midnight = Date(timeIntervalSince1970: 1_699_833_600)
        let carbRatio = try DailySchedule(entries: [
            .init(secondsSinceMidnight: 0, value: 10.0),
            .init(secondsSinceMidnight: 12 * 3_600, value: 12.0),
        ])
        let profile = TherapyProfile(
            basalSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 1.0)]),
            sensitivitySchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 50.0)]),
            carbRatioSchedule: carbRatio,
            targetSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 100.0...110.0)]),
            timeZone: utc,
            glucoseUnit: .milligramsPerDeciliter
        )
        let meal = CarbRecord(date: midnight.addingTimeInterval(8 * 3_600), grams: 40)
        let sample = CategorizedSample(
            sample: DeviationSample(
                date: midnight.addingTimeInterval(9 * 3_600),
                glucose: 150,
                averageDelta: 0,
                insulinEffect: -1,
                deviation: 20,
                insulinOnBoard: 2,
                carbsOnBoard: 20
            ),
            category: .csf,
            scheduledBasal: 1,
            scheduledISF: 50,
            mealCarbs: 20
        )

        let result = CarbRatioTuner().tuneSchedule(
            samples: [sample],
            carbs: [meal],
            currentProfile: profile,
            pumpSchedule: carbRatio,
            tunedSensitivity: []
        )

        #expect(result.map(\.tunedValue) == [10, 12])
        #expect(result.allSatisfy { $0.untuned })
    }
}

@Suite("Categorizer")
struct CategorizerTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func profile() throws -> TherapyProfile {
        TherapyProfile(
            basalSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 1.0)]),
            sensitivitySchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 50)]),
            carbRatioSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 10)]),
            targetSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 100...110)]),
            timeZone: TimeZone(identifier: "UTC")!,
            glucoseUnit: .milligramsPerDeciliter
        )
    }

    private func sample(_ i: Int, deviation: Double, bgi: Double = -1, iob: Double = 0, cob: Double = 0) -> DeviationSample {
        DeviationSample(date: base.addingTimeInterval(Double(i) * 300), glucose: 150, averageDelta: deviation, insulinEffect: bgi, deviation: deviation, insulinOnBoard: iob, carbsOnBoard: cob)
    }

    @Test("carbs-on-board makes a datum CSF")
    func csfWhenCOB() throws {
        let categorizer = Categorizer(profile: try profile())
        let result = categorizer.categorize([sample(0, deviation: 4, cob: 20)])
        #expect(result[0].category == .csf)
    }

    @Test("high deviation with UAM-as-basal folds into basal")
    func uamFoldsToBasal() throws {
        let categorizer = Categorizer(profile: try profile(), options: CategorizerOptions(categorizeUAMAsBasal: true))
        // deviation > 6 → UAM → reassigned to basal.
        let result = categorizer.categorize([sample(0, deviation: 10)])
        #expect(result[0].category == .basal)
    }

    @Test("absorbing state resets across a data gap")
    func stateResetsAcrossGap() throws {
        let categorizer = Categorizer(profile: try profile())
        // First a meal datum (COB>0) → CSF and sets absorbing; then, after a
        // >20-min gap, a datum with no COB and low deviation must NOT stay CSF.
        let meal = sample(0, deviation: 4, iob: 1.0, cob: 20)
        let afterGap = DeviationSample(
            date: base.addingTimeInterval(40 * 60), // 40-min gap
            glucose: 120, averageDelta: -1, insulinEffect: -1, deviation: -1,
            insulinOnBoard: 0.0, carbsOnBoard: 0
        )
        let result = categorizer.categorize([meal, afterGap])
        #expect(result[0].category == .csf)
        #expect(result[1].category != .csf)
    }

    @Test("negative deviation with strong insulin activity is ISF")
    func isfCase() throws {
        let categorizer = Categorizer(profile: try profile())
        // basalBGI = 1*50/60*5 ≈ 4.17; need basalBGI <= -4*bgi and avgDelta<=0.
        // With bgi = -2, -4*bgi = 8 > 4.17, and negative deviation/avgDelta → ISF.
        let s = DeviationSample(date: base, glucose: 150, averageDelta: -3, insulinEffect: -2, deviation: -3, insulinOnBoard: 0.1, carbsOnBoard: 0)
        let result = categorizer.categorize([CategorizedSample(sample: s, category: .isf, scheduledBasal: 1, scheduledISF: 50).sample])
        #expect(result[0].category == .isf)
    }
}
