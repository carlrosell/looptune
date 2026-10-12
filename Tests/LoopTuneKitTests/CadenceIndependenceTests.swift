import Testing
import Foundation
@testable import LoopTuneKit

/// CORE-05: the same glucose trajectory must carry the same tuning weight and
/// evidence duration whatever the CGM sampling cadence.
@Suite("CGM cadence independence")
struct CadenceIndependenceTests {
    /// 2023-11-15 00:00 UTC.
    private let midnight = Date(timeIntervalSince1970: 1_700_006_400)
    private let utc = TimeZone(identifier: "UTC")!

    private func profile(
        carbRatios: [DailySchedule<Double>.Entry] = [.init(secondsSinceMidnight: 0, value: 10)]
    ) throws -> TherapyProfile {
        TherapyProfile(
            basalSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 1.0)]),
            sensitivitySchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 50)]),
            carbRatioSchedule: try DailySchedule(entries: carbRatios),
            targetSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 100...110)]),
            timeZone: utc,
            glucoseUnit: .milligramsPerDeciliter,
            insulinType: .novolog
        )
    }

    /// Glucose rising 3 mg/dL per five minutes from 03:00 to 06:00.
    private func risingGlucose(spacing: TimeInterval) -> [GlucoseSample] {
        let start = midnight.addingTimeInterval(3 * 3600)
        let count = Int(3 * 3600 / spacing)
        return (0...count).map { index in
            let elapsed = Double(index) * spacing
            return GlucoseSample(
                date: start.addingTimeInterval(elapsed),
                milligramsPerDeciliter: 120 + elapsed / 300 * 3
            )
        }
    }

    private func run(_ glucose: [GlucoseSample], days: Int = 1) throws -> TuningRecommendation {
        try TuningPipeline().run(
            inputs: TuningInputs(
                profile: try profile(),
                glucose: glucose,
                doses: [],
                carbs: [],
                analysisStart: glucose.first!.date,
                analysisEnd: glucose.last!.date
            ),
            configuration: TuningConfiguration(days: days)
        )
    }

    /// Basal hours of `recommendation`, in hour order.
    private func basalHours(_ recommendation: TuningRecommendation) -> [BasalHourRecommendation] {
        recommendation.basalHours.sorted { $0.hour < $1.hour }
    }

    /// Smooth, non-linear glucose: a 140 mg/dL baseline with a three-hour,
    /// 40 mg/dL sine wave, read at `spacing` from 03:00.
    private func sineGlucose(spacing: TimeInterval, hours: Double = 3, noise: Bool = false) -> [GlucoseSample] {
        let start = midnight.addingTimeInterval(3 * 3600)
        return (0...Int(hours * 3600 / spacing)).map { index in
            let elapsed = Double(index) * spacing
            var value = 140 + 40 * sin(2 * Double.pi * elapsed / (3 * 3600))
            if noise {
                // Deterministic sensor noise keyed to the reading's minute, so
                // every cadence reads the same value at the same instant.
                let minute = Int(elapsed / 60)
                value += Double((minute * 7_919) % 11) - 5
            }
            return GlucoseSample(date: start.addingTimeInterval(elapsed), milligramsPerDeciliter: value)
        }
    }

    /// Samples of constant five-minute rates covering `[start, start + span]`.
    private func samples(
        from start: Date,
        span: TimeInterval,
        spacing: TimeInterval,
        deviation: Double,
        insulinEffect: Double = 0,
        averageDelta: Double = 0,
        carbsOnBoard: Double = 0
    ) -> [DeviationSample] {
        (1...Int(span / spacing)).map { index in
            DeviationSample(
                date: start.addingTimeInterval(Double(index) * spacing),
                glucose: 150,
                averageDelta: averageDelta,
                insulinEffect: insulinEffect,
                deviation: deviation,
                insulinOnBoard: 0,
                carbsOnBoard: carbsOnBoard,
                duration: spacing
            )
        }
    }

    @Test("replay records each interval's duration alongside its five-minute rate")
    func replayRecordsDuration() throws {
        for spacing in [60.0, 300.0, 900.0] {
            let glucose = risingGlucose(spacing: spacing)
            let deviations = try ReplayEngine().computeDeviations(
                glucose: glucose,
                doses: [],
                carbs: [],
                profile: try profile(),
                analysisStart: glucose.first!.date,
                analysisEnd: glucose.last!.date
            )
            #expect(deviations.allSatisfy { $0.duration == spacing })
            #expect(deviations.allSatisfy { abs($0.deviation - 3) < 1e-9 })
            #expect(DeviationSample.fiveMinuteIntervals(of: deviations) == 36)
        }
    }

    /// Before the fix the hour-3 basal was 1.2, 1.097 and 1.037 for 60, 300
    /// and 900-second spacing, and total evidence was 180, 36 and 12 samples.
    ///
    /// Tolerance: each interval is attributed to the clock hour of its end
    /// (oref0's convention), so evidence near an hour boundary can shift by
    /// less than one CGM interval between adjacent hours. Over this trajectory
    /// that moves a basal rate by at most 0.01 U/h, well under one 0.05 U/h
    /// pump increment.
    @Test("equivalent trajectories give equivalent basal recommendations and evidence")
    func pipelineBasalIsCadenceIndependent() throws {
        let reference = try run(risingGlucose(spacing: 300))
        let referenceRates = reference.basalHours.sorted { $0.hour < $1.hour }
        #expect(reference.totalSamples == 36)

        for spacing in [60.0, 900.0] {
            let recommendation = try run(risingGlucose(spacing: spacing))
            #expect(recommendation.totalSamples == reference.totalSamples)
            #expect(recommendation.categoryCounts == reference.categoryCounts)
            let rates = recommendation.basalHours.sorted { $0.hour < $1.hour }
            for (hour, reference) in zip(rates, referenceRates) {
                #expect(abs(hour.recommendedRate - reference.recommendedRate) <= 0.0101, "hour \(hour.hour) at \(spacing) s")
                #expect(hour.roundedRate() == reference.roundedRate(), "hour \(hour.hour) at \(spacing) s")
                // Boundary shift is at most one interval (three five-minute
                // intervals at 15-minute spacing) per contributing hour.
                #expect(abs(hour.sampleCount - reference.sampleCount) <= 3, "hour \(hour.hour) at \(spacing) s")
            }
        }
    }

    @Test("basal sums and evidence are identical when no interval crosses an hour")
    func basalTunerWeightsByDuration() throws {
        let tuner = BasalTuner(timeZone: utc)
        let flat = [Double](repeating: 1.0, count: 24)
        func tune(spacing: TimeInterval) -> BasalTuner.Result {
            let categorized = samples(
                from: midnight.addingTimeInterval(3600 + 600),
                span: 40 * 60,
                spacing: spacing,
                deviation: 2.5
            ).map { CategorizedSample(sample: $0, category: .basal, scheduledBasal: 1, scheduledISF: 50) }
            return tuner.tune(samples: categorized, currentHourly: flat, pumpHourly: flat, isf: 50)
        }
        let reference = tune(spacing: 300)
        #expect(reference.hourlyRates[23] > 1)
        #expect(reference.sampleCounts[23] == 8)
        for spacing in [60.0, 600.0] {
            #expect(tune(spacing: spacing) == reference)
        }
    }

    @Test("meal residuals are weighted by duration")
    func carbRatioIsCadenceIndependent() throws {
        let profile = try profile()
        let mealTime = midnight.addingTimeInterval(12 * 3600)
        let meal = CarbRecord(date: mealTime, grams: 40, absorptionTime: 3 * 3600)
        func tune(spacing: TimeInterval) throws -> TuningOutput {
            try LoopTuner().tune(
                deviations: samples(from: mealTime, span: 2 * 3600, spacing: spacing, deviation: 1.5, carbsOnBoard: 20),
                carbs: [meal],
                currentProfile: profile,
                pumpProfile: profile,
                analysisStart: mealTime,
                analysisEnd: mealTime.addingTimeInterval(2 * 3600)
            )
        }
        let reference = try tune(spacing: 300)
        #expect(reference.carbRatioSchedule[0].tunedValue < 10)
        #expect(reference.categoryCounts[.csf] == 24)
        for spacing in [60.0, 900.0] {
            let output = try tune(spacing: spacing)
            #expect(abs(output.carbRatioSchedule[0].tunedValue - reference.carbRatioSchedule[0].tunedValue) < 1e-9)
            #expect(output.categoryCounts == reference.categoryCounts)
            #expect(output.totalSamples == reference.totalSamples)
        }
    }

    @Test("ISF needs fifty minutes of usable evidence, not ten readings")
    func sensitivityMinimumMeasuresDuration() throws {
        let tuner = SensitivityTuner()
        func tune(minutes: Double, spacing: TimeInterval) -> SensitivityTuner.Result {
            let categorized = samples(
                from: midnight,
                span: minutes * 60,
                spacing: spacing,
                deviation: 1,
                insulinEffect: -3,
                averageDelta: -1
            ).map { CategorizedSample(sample: $0, category: .isf, scheduledBasal: 1, scheduledISF: 50) }
            return tuner.tuneWithEvidence(samples: categorized, currentISF: 50, pumpISF: 50)
        }

        let tenOneMinuteReadings = tune(minutes: 10, spacing: 60)
        #expect(tenOneMinuteReadings.untuned)
        #expect(tenOneMinuteReadings.usableSampleCount == 2)

        let reference = tune(minutes: 50, spacing: 300)
        #expect(!reference.untuned)
        #expect(reference.usableSampleCount == 10)
        #expect(tune(minutes: 50, spacing: 60) == reference)
        #expect(tune(minutes: 45, spacing: 900).untuned)
    }

    @Test("the pipeline minimum measures one hour of evidence, not twelve readings")
    func pipelineMinimumMeasuresDuration() throws {
        let start = midnight.addingTimeInterval(3 * 3600)
        func glucose(minutes: Int, spacing: TimeInterval) -> [GlucoseSample] {
            (0...Int(Double(minutes * 60) / spacing)).map { index in
                GlucoseSample(date: start.addingTimeInterval(Double(index) * spacing), milligramsPerDeciliter: 120)
            }
        }

        #expect(throws: TuningPipeline.PipelineError.insufficientUsableData(minimum: 12, actual: 2)) {
            _ = try run(glucose(minutes: 12, spacing: 60))
        }
        #expect(throws: TuningPipeline.PipelineError.insufficientUsableData(minimum: 12, actual: 11)) {
            _ = try run(glucose(minutes: 55, spacing: 60))
        }
        #expect(try run(glucose(minutes: 60, spacing: 60)).totalSamples == 12)
        #expect(try run(glucose(minutes: 60, spacing: 300)).totalSamples == 12)
        #expect(try run(glucose(minutes: 60, spacing: 900)).totalSamples == 12)
    }

    @Test("the chained per-day minimum measures duration")
    func chainedMinimumMeasuresDuration() throws {
        // Two days of 12-minute one-minute windows: each holds twelve
        // readings but under one hour of evidence, so neither day is tuned.
        let profile = try profile()
        var glucose: [GlucoseSample] = []
        for day in 0..<2 {
            let windowStart = midnight.addingTimeInterval(Double(day) * 86_400 + 12 * 3600)
            glucose += (0...12).map { minute in
                GlucoseSample(date: windowStart.addingTimeInterval(Double(minute) * 60), milligramsPerDeciliter: 120)
            }
        }
        let result = try ChainedTuner().run(inputs: TuningInputs(
            profile: profile,
            glucose: glucose,
            doses: [],
            carbs: [],
            analysisStart: midnight,
            analysisEnd: midnight.addingTimeInterval(2 * 86_400)
        ))
        #expect(result.daysTuned == 0)
        #expect(result.output.totalSamples == 0)
    }

    @Test("jittered five-minute timestamps keep the evidence and recommendation of a regular grid")
    func jitteredFiveMinuteData() throws {
        let regular = risingGlucose(spacing: 300)
        // Up to ±30 s of jitter on every interior reading; the window ends stay
        // fixed so both runs cover the same three hours.
        let offsets: [TimeInterval] = [20, -25, 30, -10, 5, -30, 15, 25, -20, 10]
        let jittered = regular.enumerated().map { index, reading in
            guard index > 0, index < regular.count - 1 else { return reading }
            return GlucoseSample(
                date: reading.date.addingTimeInterval(offsets[index % offsets.count]),
                milligramsPerDeciliter: 120 + reading.date.addingTimeInterval(offsets[index % offsets.count])
                    .timeIntervalSince(regular[0].date) / 300 * 3
            )
        }
        let reference = try run(regular)
        let recommendation = try run(jittered)

        #expect(recommendation.totalSamples == 36)
        #expect(recommendation.categoryCounts == reference.categoryCounts)
        for (hour, expected) in zip(basalHours(recommendation), basalHours(reference)) {
            // Jitter can move one reading across an hour boundary.
            #expect(abs(hour.recommendedRate - expected.recommendedRate) <= 0.0101, "hour \(hour.hour)")
            #expect(hour.roundedRate() == expected.roundedRate(), "hour \(hour.hour)")
            #expect(abs(hour.sampleCount - expected.sampleCount) <= 1, "hour \(hour.hour)")
        }
    }

    @Test("supported missing-reading gaps count by their duration")
    func supportedGapsCountByDuration() throws {
        let complete = risingGlucose(spacing: 300)
        // Drop one, two and three readings inside hours 3, 4 and 5, leaving
        // 10, 15 and 20-minute intervals, all within the 20-minute limit.
        let dropped: Set<Int> = [4, 17, 18, 29, 30, 31]
        let gapped = complete.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        let deviations = try ReplayEngine().computeDeviations(
            glucose: gapped,
            doses: [],
            carbs: [],
            profile: try profile(),
            analysisStart: gapped.first!.date,
            analysisEnd: gapped.last!.date
        )
        #expect(Set(deviations.map(\.duration)) == [300, 600, 900, 1200])
        #expect(DeviationSample.totalDuration(of: deviations) == 3 * 3600)

        let reference = try run(complete)
        let recommendation = try run(gapped)
        #expect(recommendation.totalSamples == reference.totalSamples)
        #expect(recommendation.categoryCounts == reference.categoryCounts)
        for (hour, expected) in zip(basalHours(recommendation), basalHours(reference)) {
            #expect(abs(hour.recommendedRate - expected.recommendedRate) < 1e-9, "hour \(hour.hour)")
            #expect(hour.sampleCount == expected.sampleCount, "hour \(hour.hour)")
        }
    }

    @Test("an interval longer than the gap limit adds no weight or evidence")
    func rejectedGapAddsNoEvidence() throws {
        let complete = risingGlucose(spacing: 300)
        // Drop 04:05 through 04:25: the 30-minute interval ending at 04:30 is
        // rejected, so the six five-minute intervals ending 04:05 to 04:30
        // contribute nothing.
        let gapped = complete.filter { reading in
            let minutes = reading.date.timeIntervalSince(midnight) / 60
            return !(245...265).contains(minutes)
        }
        let reference = try run(complete)
        let recommendation = try run(gapped)

        #expect(recommendation.totalSamples == reference.totalSamples - 6)
        #expect(recommendation.categoryCounts[.basal] == reference.totalSamples - 6)
        for (hour, expected) in zip(basalHours(recommendation), basalHours(reference)) {
            // Deviations observed in hour 4 inform basal hours 1 to 3.
            let lost = (1...3).contains(hour.hour) ? 6 : 0
            #expect(hour.sampleCount == expected.sampleCount - lost, "hour \(hour.hour)")
            if lost > 0 {
                #expect(hour.recommendedRate < expected.recommendedRate, "hour \(hour.hour)")
            }
        }
    }

    /// Two days of a 24-hour sine wave through the chained (multi-day) entry
    /// point. Before the fix one-minute data carried five times the weight of
    /// five-minute data. Tolerance: hour-boundary attribution shifts by less
    /// than one interval per hour each day, which moves a rate by at most
    /// 0.012 U/h here, under a quarter of a 0.05 U/h pump increment.
    @Test("the chained entry point gives equivalent recommendations at 1, 5 and 15-minute cadence")
    func chainedBasalIsCadenceIndependent() throws {
        let start = midnight.addingTimeInterval(4 * 3600)
        func glucose(spacing: TimeInterval) -> [GlucoseSample] {
            (0...Int(2 * 86_400 / spacing)).map { index in
                let elapsed = Double(index) * spacing
                return GlucoseSample(
                    date: start.addingTimeInterval(elapsed),
                    milligramsPerDeciliter: 140 + 60 * sin(2 * Double.pi * elapsed / 86_400)
                )
            }
        }
        let reference = try run(glucose(spacing: 300), days: 2)
        #expect(reference.daysAnalyzed == 2)
        #expect(reference.totalSamples == 576)
        #expect(basalHours(reference).contains { abs($0.recommendedRate - 1) > 0.1 })

        for spacing in [60.0, 900.0] {
            let recommendation = try run(glucose(spacing: spacing), days: 2)
            #expect(recommendation.totalSamples == reference.totalSamples)
            #expect(recommendation.categoryCounts == reference.categoryCounts)
            for (hour, expected) in zip(basalHours(recommendation), basalHours(reference)) {
                #expect(abs(hour.recommendedRate - expected.recommendedRate) <= 0.015, "hour \(hour.hour) at \(spacing) s")
                #expect(hour.sampleCount == expected.sampleCount, "hour \(hour.hour) at \(spacing) s")
                #expect(hour.daysMissing == expected.daysMissing, "hour \(hour.hour) at \(spacing) s")
            }
        }
    }

    @Test("per-block carb ratios weight meal residuals by duration")
    func carbRatioScheduleIsCadenceIndependent() throws {
        let profile = try profile(carbRatios: [
            .init(secondsSinceMidnight: 0, value: 10),
            .init(secondsSinceMidnight: 12 * 3600, value: 12),
        ])
        let breakfast = CarbRecord(date: midnight.addingTimeInterval(7 * 3600), grams: 30, absorptionTime: 3 * 3600)
        let lunch = CarbRecord(date: midnight.addingTimeInterval(13 * 3600), grams: 50, absorptionTime: 3 * 3600)
        func tune(spacing: TimeInterval) throws -> TuningOutput {
            let deviations = samples(from: breakfast.date, span: 2 * 3600, spacing: spacing, deviation: 1.5, carbsOnBoard: 20)
                + samples(from: lunch.date, span: 2 * 3600, spacing: spacing, deviation: -1, carbsOnBoard: 20)
            return try LoopTuner().tune(
                deviations: deviations,
                carbs: [breakfast, lunch],
                currentProfile: profile,
                pumpProfile: profile,
                analysisStart: midnight,
                analysisEnd: midnight.addingTimeInterval(86_400)
            )
        }
        let reference = try tune(spacing: 300)
        #expect(reference.carbRatioSchedule.count == 2)
        #expect(reference.carbRatioSchedule[0].tunedValue < 10)
        #expect(reference.carbRatioSchedule[1].tunedValue > 12)
        #expect(reference.categoryCounts[.csf] == 48)
        for spacing in [60.0, 900.0] {
            let output = try tune(spacing: spacing)
            for (block, expected) in zip(output.carbRatioSchedule, reference.carbRatioSchedule) {
                #expect(abs(block.tunedValue - expected.tunedValue) < 1e-9, "block \(block.secondsSinceMidnight) at \(spacing) s")
                #expect(block.evidenceCount == expected.evidenceCount)
            }
            #expect(output.categoryCounts == reference.categoryCounts)
        }
    }

    @Test("the trailing glucose delta covers twenty minutes at any cadence")
    func averageDeltaHorizonIsTimeBased() throws {
        // Exact twenty-minute secant of the sine wave, per five minutes.
        func expected(at elapsed: TimeInterval) -> Double {
            func value(_ t: TimeInterval) -> Double { 140 + 40 * sin(2 * Double.pi * t / (3 * 3600)) }
            return (value(elapsed) - value(elapsed - 1200)) / 4
        }
        func deltas(spacing: TimeInterval, noise: Bool = false) -> [Date: Double] {
            let glucose = sineGlucose(spacing: spacing, noise: noise)
            var result: [Date: Double] = [:]
            for index in glucose.indices {
                result[glucose[index].date] = ReplayEngine.averageDelta(in: glucose, endingAt: index)
            }
            return result
        }
        let start = midnight.addingTimeInterval(3 * 3600)
        // Instants every cadence reads, once twenty minutes of history exist.
        let shared = stride(from: 1800.0, through: 3 * 3600, by: 900).map { start.addingTimeInterval($0) }

        let oneMinute = deltas(spacing: 60)
        let fiveMinute = deltas(spacing: 300)
        let fifteenMinute = deltas(spacing: 900)
        for date in shared {
            let elapsed = date.timeIntervalSince(start)
            #expect(abs(oneMinute[date]! - expected(at: elapsed)) < 1e-9)
            #expect(abs(fiveMinute[date]! - expected(at: elapsed)) < 1e-9)
            // Fifteen-minute readings bracket the horizon, so glucose there is
            // interpolated. Linear interpolation over 15 minutes of this curve
            // errs by at most 1.4 mg/dL, 0.35 mg/dL per five minutes. Four
            // fifteen-minute readings would instead span an hour.
            #expect(abs(fifteenMinute[date]! - expected(at: elapsed)) < 0.35)
        }

        // With sensor noise the one-minute and five-minute values still agree,
        // because both read the same instants twenty minutes apart.
        let noisyOneMinute = deltas(spacing: 60, noise: true)
        let noisyFiveMinute = deltas(spacing: 300, noise: true)
        for date in noisyFiveMinute.keys where date.timeIntervalSince(start) >= 1200 {
            #expect(abs(noisyOneMinute[date]! - noisyFiveMinute[date]!) < 1e-9)
        }
    }

    @Test("replay carries the time-based trailing delta into each sample")
    func replayAverageDeltaIsCadenceIndependent() throws {
        func averageDeltas(spacing: TimeInterval) throws -> [Date: Double] {
            let glucose = sineGlucose(spacing: spacing, noise: true)
            let deviations = try ReplayEngine().computeDeviations(
                glucose: glucose,
                doses: [DoseRecord(kind: .bolus(units: 1.5), startDate: glucose[0].date, endDate: glucose[0].date)],
                carbs: [],
                profile: try profile(),
                analysisStart: glucose[0].date.addingTimeInterval(1200),
                analysisEnd: glucose.last!.date
            )
            return Dictionary(uniqueKeysWithValues: deviations.map { ($0.date, $0.averageDelta) })
        }
        let oneMinute = try averageDeltas(spacing: 60)
        let fiveMinute = try averageDeltas(spacing: 300)
        #expect(fiveMinute.count == 32)
        for (date, delta) in fiveMinute {
            #expect(abs(oneMinute[date]! - delta) < 1e-9)
        }
    }

    @Test("a short gap at the horizon is interpolated and a long gap ends the trailing delta")
    func averageDeltaAcrossGaps() {
        let start = midnight
        func reading(_ minutes: Double, _ value: Double) -> GlucoseSample {
            GlucoseSample(date: start.addingTimeInterval(minutes * 60), milligramsPerDeciliter: value)
        }
        // Readings at 0, 15 and 35 minutes: twenty minutes back from 35 is 15.
        #expect(ReplayEngine.averageDelta(in: [reading(0, 100), reading(15, 130), reading(35, 150)], endingAt: 2) == 5)
        // Readings at 0, 10, 25 and 35: glucose at 15 is interpolated between
        // the readings at 10 (120) and 25 (150), giving 130.
        let bracketed = [reading(0, 100), reading(10, 120), reading(25, 150), reading(35, 170)]
        #expect(abs(ReplayEngine.averageDelta(in: bracketed, endingAt: 3) - 10) < 1e-9)
        // A 30-minute gap ends the walk back: only the last interval counts.
        let gapped = [reading(0, 100), reading(30, 180), reading(40, 190)]
        #expect(ReplayEngine.averageDelta(in: gapped, endingAt: 2) == 5)
    }

    @Test("minimums compare evidence duration, not rounded counts")
    func minimumsCompareDuration() throws {
        // 58 minutes of one-minute CGM rounds to twelve intervals but holds
        // under an hour, so it is rejected and reported as eleven.
        let start = midnight.addingTimeInterval(3 * 3600)
        let glucose = (0...58).map { minute in
            GlucoseSample(date: start.addingTimeInterval(Double(minute) * 60), milligramsPerDeciliter: 120)
        }
        #expect(throws: TuningPipeline.PipelineError.insufficientUsableData(minimum: 12, actual: 11)) {
            _ = try run(glucose)
        }

        // 48 minutes of ISF evidence rounds to ten intervals but is under 50
        // minutes, so ISF is untuned and reports nine.
        let categorized = samples(
            from: midnight,
            span: 48 * 60,
            spacing: 60,
            deviation: 1,
            insulinEffect: -3,
            averageDelta: -1
        ).map { CategorizedSample(sample: $0, category: .isf, scheduledBasal: 1, scheduledISF: 50) }
        let result = SensitivityTuner().tuneWithEvidence(samples: categorized, currentISF: 50, pumpISF: 50)
        #expect(result.untuned)
        #expect(result.usableSampleCount == 9)
    }

    @Test("reported counts show any evidence and categories add up to the total")
    func reportedCounts() {
        #expect(DeviationSample.fiveMinuteIntervals(in: 0) == 0)
        #expect(DeviationSample.fiveMinuteIntervals(in: 60) == 1)
        #expect(DeviationSample.fiveMinuteIntervals(in: 3450) == 12)
        #expect(DeviationSample.completeFiveMinuteIntervals(in: 3450) == 11)

        // Each duration rounds up alone (3 + 3 + 3 = 9), but together they
        // hold 7.5 intervals, reported as 8.
        let apportioned = DeviationSample.fiveMinuteIntervals(apportioning: [750, 750, 750])
        #expect(apportioned.reduce(0, +) == 8)
        #expect(apportioned == [3, 3, 2])
        #expect(DeviationSample.fiveMinuteIntervals(apportioning: [60, 0, 3600]) == [0, 0, 12])
    }

    // Exit tests need Swift 6.2; CI still builds with 6.1.
    #if compiler(>=6.2)
    @Test("a sample's duration must be finite and positive")
    func durationIsValidated() async {
        await #expect(processExitsWith: .failure) {
            _ = DeviationSample(
                date: Date(timeIntervalSince1970: 0),
                glucose: 120,
                averageDelta: 0,
                insulinEffect: 0,
                deviation: 0,
                insulinOnBoard: 0,
                carbsOnBoard: 0,
                duration: -300
            )
        }
    }
    #endif

    @Test("weighted median reduces to oref0's percentile and favors longer evidence")
    func weightedMedian() {
        let values: [Double] = [0.9, 1.4, 0.7, 1.1, 1.0, 1.3, 0.8, 1.2, 0.95, 1.05, 1.15]
        for count in 1...values.count {
            let subset = Array(values.prefix(count))
            let expected = TuningMath.median(subset)
            #expect(TuningMath.weightedMedian(subset.map { ($0, 1) }) == expected)
            #expect(abs(TuningMath.weightedMedian(subset.map { ($0, 0.2) }) - expected) < 1e-12)
        }
        // A fifteen-minute interval outweighs two five-minute ones.
        #expect(TuningMath.weightedMedian([(0.8, 1), (0.9, 1), (1.2, 3)]) == 1.2)
        #expect(TuningMath.weightedMedian([(0.8, 1), (0.9, 1), (1.2, 1)]) == TuningMath.median([0.8, 0.9, 1.2]))
    }
}
