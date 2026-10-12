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

    private func profile() throws -> TherapyProfile {
        TherapyProfile(
            basalSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 1.0)]),
            sensitivitySchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 50)]),
            carbRatioSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 10)]),
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

    private func run(_ glucose: [GlucoseSample]) throws -> TuningRecommendation {
        try TuningPipeline().run(
            inputs: TuningInputs(
                profile: try profile(),
                glucose: glucose,
                doses: [],
                carbs: [],
                analysisStart: glucose.first!.date,
                analysisEnd: glucose.last!.date
            ),
            configuration: TuningConfiguration(days: 1)
        )
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
