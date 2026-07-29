import Testing
import Foundation
import LoopAlgorithm
@testable import LoopTuneKit

@Suite("ReplayEngine")
struct ReplayEngineTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func flatProfile() throws -> TherapyProfile {
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

    /// Build an evenly-spaced 5-minute glucose series from a value generator.
    private func series(count: Int, start: Double, step: (Int) -> Double) -> [GlucoseSample] {
        (0..<count).map { i in
            GlucoseSample(date: base.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: start + step(i))
        }
    }

    @Test("requires at least two glucose samples")
    func requiresGlucose() throws {
        let profile = try flatProfile()
        #expect(throws: ReplayEngine.ReplayError.insufficientGlucose) {
            _ = try ReplayEngine().computeDeviations(
                glucose: [GlucoseSample(date: base, milligramsPerDeciliter: 120)],
                doses: [], carbs: [], profile: profile,
                analysisStart: base, analysisEnd: base.addingTimeInterval(3600)
            )
        }
    }

    @Test("with no insulin or carbs, deviation equals observed glucose change")
    func deviationEqualsObservedWhenNoInsulin() throws {
        let profile = try flatProfile()
        // Rising +2 mg/dL every 5 min from 120; no doses, no carbs. Delivery
        // equals scheduled basal, so the modeled insulin/carb effects are zero.
        let glucose = series(count: 12, start: 120) { Double($0) * 2 }
        let samples = try ReplayEngine().computeDeviations(
            glucose: glucose, doses: [], carbs: [], profile: profile,
            analysisStart: base, analysisEnd: glucose.last!.date
        )
        #expect(!samples.isEmpty)
        for sample in samples {
            #expect(abs(sample.insulinEffect) < 1e-6)
            #expect(abs(sample.deviation - 2.0) < 1e-6)
            #expect(sample.deviation.isFinite)
        }
        // avgDelta converges to +2 once four points are available.
        #expect(abs(samples.last!.averageDelta - 2.0) < 1e-6)
    }

    @Test("a bolus produces a negative insulin effect and positive deviation when glucose stays flat")
    func bolusInsulinEffect() throws {
        let profile = try flatProfile()
        // Flat glucose at 150 despite a 2 U bolus at the start: insulin was
        // active (negative effect) but BG didn't fall, so deviations are positive.
        let glucose = series(count: 18, start: 150) { _ in 0 }
        let dose = DoseRecord(kind: .bolus(units: 2.0), startDate: base, endDate: base)
        let samples = try ReplayEngine().computeDeviations(
            glucose: glucose, doses: [dose], carbs: [], profile: profile,
            analysisStart: base, analysisEnd: glucose.last!.date
        )
        #expect(!samples.isEmpty)
        // Loop's insulin model has a 10-minute delay, so the earliest intervals
        // carry no insulin effect. Once activity is present the modeled effect is
        // negative, and with flat glucose the deviation is correspondingly positive.
        let active = samples.filter { $0.insulinEffect < -0.001 }
        #expect(!active.isEmpty)
        for sample in active {
            #expect(sample.deviation > 0)
        }
        // Net modeled insulin effect over the window is a drop.
        let totalInsulinEffect = samples.reduce(0) { $0 + $1.insulinEffect }
        #expect(totalInsulinEffect < 0)
        // IOB should be near the bolus size early and decay over time.
        #expect(samples.first!.insulinOnBoard > 1.5)
        #expect(samples.last!.insulinOnBoard < samples.first!.insulinOnBoard)
    }

    @Test("carbs raise carbs-on-board and are attributed to carb effect, not deviation")
    func carbsOnBoard() throws {
        let profile = try flatProfile()
        // Glucose rising after a meal; the modeled carb effect should absorb the
        // rise so deviations stay modest, and COB should be positive early.
        let glucose = series(count: 24, start: 120) { min(Double($0) * 3, 60) }
        let carb = CarbRecord(date: base, grams: 40, absorptionTime: 3 * 3600)
        let samples = try ReplayEngine().computeDeviations(
            glucose: glucose, doses: [], carbs: [carb], profile: profile,
            analysisStart: base, analysisEnd: glucose.last!.date
        )
        #expect(!samples.isEmpty)
        #expect(samples.contains { $0.carbsOnBoard > 0 })
        for sample in samples {
            #expect(sample.deviation.isFinite)
            #expect(sample.carbsOnBoard >= 0)
        }
    }

    @Test("long CGM gaps are skipped")
    func skipsLongGaps() throws {
        let profile = try flatProfile()
        var glucose = series(count: 6, start: 120) { Double($0) * 2 }
        // Insert a 40-minute gap before an extra sample.
        glucose.append(GlucoseSample(date: base.addingTimeInterval(6 * 300 + 40 * 60), milligramsPerDeciliter: 140))
        let samples = try ReplayEngine().computeDeviations(
            glucose: glucose, doses: [], carbs: [], profile: profile,
            analysisStart: base, analysisEnd: glucose.last!.date
        )
        // The gapped interval must not appear.
        #expect(!samples.contains { $0.date == glucose.last!.date })
    }

    @Test("accepted irregular intervals are normalized to five-minute deltas")
    func normalizesIrregularIntervals() throws {
        let profile = try flatProfile()
        let glucose = (0..<6).map { index in
            GlucoseSample(
                date: base.addingTimeInterval(Double(index) * 15 * 60),
                milligramsPerDeciliter: 120 + Double(index) * 15
            )
        }
        let samples = try ReplayEngine().computeDeviations(
            glucose: glucose,
            doses: [],
            carbs: [],
            profile: profile,
            analysisStart: base,
            analysisEnd: glucose.last!.date
        )
        #expect(samples.count == 5)
        #expect(samples.allSatisfy { abs($0.deviation - 5) < 1e-9 })
        #expect(samples.allSatisfy { abs($0.averageDelta - 5) < 1e-9 })
    }
}
