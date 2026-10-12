import Testing
import Foundation
@testable import LoopTuneKit

/// CORE-02: the basal value a user enters into Loop must stay inside both the
/// pump-relative tuning caps and Loop's absolute basal limits after rounding.
@Suite("Final basal limits")
struct BasalLimitTests {
    private static let caps = TuningCaps()
    private static let absolute = LoopGuardrails.basalRate

    /// A recommendation whose hour 0 carries the case under test; the other
    /// hours are unchanged 1.0 U/hr.
    private func recommendation(pump: Double, tuned: Double) throws -> TuningRecommendation {
        var pumpHourly = Array(repeating: 1.0, count: 24)
        var tunedHourly = Array(repeating: 1.0, count: 24)
        pumpHourly[0] = pump
        tunedHourly[0] = tuned
        return try recommendation(pumpHourly: pumpHourly, tunedHourly: tunedHourly)
    }

    private func recommendation(pumpHourly: [Double], tunedHourly: [Double]) throws -> TuningRecommendation {
        let output = TuningOutput(
            tunedBasalHourly: tunedHourly,
            pumpBasalHourly: pumpHourly,
            untunedBasalHours: Array(repeating: false, count: 24),
            tunedISF: 50, pumpISF: 50, tunedCarbRatio: 10, pumpCarbRatio: 10,
            categoryCounts: [:], totalSamples: 100
        )
        return try TuningRecommendation(from: output, daysAnalyzed: 1)
    }

    private func finalRate(pump: Double, tuned: Double, increment: Double = 0.05) throws -> Double {
        try recommendation(pump: pump, tuned: tuned).basalHours[0].roundedRate(toIncrement: increment)
    }

    @Test("a zero pump rate stays zero in every output")
    func zeroRateIsPreserved() throws {
        let rec = try recommendation(
            pumpHourly: Array(repeating: 0, count: 24),
            tunedHourly: Array(repeating: 0, count: 24)
        )
        #expect(rec.basalHours.allSatisfy { $0.recommendedRate == 0 && $0.roundedRate() == 0 })
        #expect(rec.tunedDailyBasal == 0)
        #expect(rec.roundedDailyBasal() == 0)
        #expect(rec.loopBasalSchedule() == [LoopBasalEntry(startMinutes: 0, rate: 0)])

        let json = try basalJSON(rec)
        #expect((json["roundedDailyBasal"] as? Double) == 0)
        let hours = try #require(json["basal"] as? [[String: Any]])
        #expect(hours.allSatisfy { ($0["recommended"] as? Double) == 0 && ($0["recommendedRounded"] as? Double) == 0 })
    }

    @Test("rounding never moves a capped rate past the relative cap")
    func cappedRateRoundsInsideCap() throws {
        // 0.15 × 1.2 = 0.18; the nearest 0.05 step, 0.20, is a 33% increase.
        #expect(try finalRate(pump: 0.15, tuned: 0.18) == 0.15)
        // Finer increments can still move toward the cap.
        #expect(try finalRate(pump: 0.15, tuned: 0.18, increment: 0.025) == 0.175)
    }

    @Test(
        "small rates respect both absolute and relative limits",
        arguments: [
            // (pump, tuned, increment, expected final rate)
            (0.05, 0.035, 0.05, 0.05),  // 30% cut is below the 0.05 absolute minimum
            (0.05, 0.06, 0.05, 0.05),   // 0.10 would be +100%
            (0.06, 0.042, 0.05, 0.05),  // relative floor 0.042 < absolute floor 0.05
            (0.10, 0.07, 0.05, 0.10),   // 0.05 would be −50%
            (0.20, 0.14, 0.05, 0.15),   // the floor rounds up into the interval
            (0.20, 0.24, 0.05, 0.20),   // 0.25 would be +25%
            (0.25, 0.30, 0.05, 0.30),   // the cap itself is representable
            (0.35, 0.245, 0.05, 0.25),  // the floor itself is representable
            (0.12, 0.084, 0.025, 0.1),  // 0.075 would be −37.5%
            (28.0, 33.6, 0.05, 30.0),   // the absolute maximum wins over +20%
        ] as [(Double, Double, Double, Double)]
    )
    func smallRateBoundaries(_ pump: Double, _ tuned: Double, _ increment: Double, _ expected: Double) throws {
        #expect(try finalRate(pump: pump, tuned: tuned, increment: increment) == expected)
    }

    @Test("an interval without a pump increment keeps the current rate")
    func noRepresentableRate() throws {
        // 0.08 permits 0.056…0.096: neither 0.05 nor 0.10 fits.
        let between = try recommendation(pump: 0.08, tuned: 0.096).basalHours[0]
        #expect(between.roundedRate() == 0.08)
        // 0.03 permits at most 0.036, below the 0.05 absolute minimum.
        let belowMinimum = try recommendation(pump: 0.03, tuned: 0.021).basalHours[0]
        #expect(belowMinimum.recommendedRate == 0.03)
        #expect(belowMinimum.roundedRate() == 0.03)
    }

    @Test("every final rate is the pump rate or a permitted increment")
    func sweepStaysInsideLimits() throws {
        for increment in [0.025, 0.05, 0.1] {
            for step in 0...400 {
                let pump = Double(step) * 0.005
                for fraction in stride(from: 0.0, through: 1.0, by: 0.125) {
                    let tuned = pump * (Self.caps.autotuneMin + (Self.caps.autotuneMax - Self.caps.autotuneMin) * fraction)
                    let hour = try recommendation(pump: pump, tuned: tuned).basalHours[0]
                    let rate = hour.roundedRate(toIncrement: increment)
                    if pump == 0 {
                        #expect(rate == 0)
                        continue
                    }
                    if rate == pump { continue }
                    let lower = max(pump * Self.caps.autotuneMin, Self.absolute.absoluteMin)
                    let upper = min(pump * Self.caps.autotuneMax, Self.absolute.absoluteMax)
                    #expect(rate >= lower - 1e-9 && rate <= upper + 1e-9, "pump \(pump) tuned \(tuned) increment \(increment) → \(rate)")
                    let steps = rate / increment
                    #expect(abs(steps - steps.rounded()) < 1e-6, "\(rate) is not a multiple of \(increment)")
                    #expect(hour.recommendedRate >= lower - 1e-9 && hour.recommendedRate <= upper + 1e-9)
                }
            }
        }
    }

    @Test("displayed, exported, Loop-entry, and daily-total values agree")
    func outputsUseTheFinalRate() throws {
        var pumpHourly = Array(repeating: 1.0, count: 24)
        var tunedHourly = Array(repeating: 1.0, count: 24)
        (pumpHourly[0], tunedHourly[0]) = (0, 0)
        (pumpHourly[1], tunedHourly[1]) = (0.15, 0.18)
        (pumpHourly[2], tunedHourly[2]) = (0.08, 0.096)
        let rec = try recommendation(pumpHourly: pumpHourly, tunedHourly: tunedHourly)
        let finals = rec.basalHours.map { $0.roundedRate() }
        #expect(Array(finals.prefix(3)) == [0, 0.15, 0.08])
        #expect(abs(rec.roundedDailyBasal() - finals.reduce(0, +)) < 1e-9)

        let json = try basalJSON(rec)
        let hours = try #require(json["basal"] as? [[String: Any]])
        #expect(hours.compactMap { $0["recommendedRounded"] as? Double } == finals)
        #expect(abs(((json["roundedDailyBasal"] as? Double) ?? -1) - finals.reduce(0, +)) < 1e-9)
        let loopRates = try #require(json["loopBasalSchedule"] as? [[String: Any]]).compactMap { $0["rate"] as? Double }
        #expect(loopRates == [0, 0.15, 0.08, 1.0])
        #expect(rec.loopBasalSchedule().map(\.rate) == loopRates)

        let report = TuningReport.render(rec)
        #expect(report.contains("01:00   0.150       0.180       0.15"))
        #expect(!report.contains("0.20"))
    }

    @Test("decoded saved runs round inside the limits")
    func decodedRunsKeepLimits() throws {
        let rec = try recommendation(pump: 0.15, tuned: 0.18)
        let decoded = try JSONDecoder().decode(TuningRecommendation.self, from: JSONEncoder().encode(rec))
        #expect(decoded == rec)
        #expect(decoded.basalHours[0].roundedRate() == 0.15)

        // Runs saved before the limits were stored derive them from the pump rate.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(rec)) as? [String: Any])
        var hours = try #require(object["basalHours"] as? [[String: Any]])
        hours = hours.map { $0.filter { $0.key != "minimumRate" && $0.key != "maximumRate" } }
        object["basalHours"] = hours
        let legacy = try JSONDecoder().decode(
            TuningRecommendation.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.basalHours[0].roundedRate() == 0.15)
        #expect(legacy.basalHours[0].maximumRate == rec.basalHours[0].maximumRate)
    }

    @Test(
        "change tier and status describe the rate entered into Loop",
        arguments: [
            // (pump, tuned, increment, final rate, final tier, report flag)
            (0.15, 0.18, 0.05, 0.15, ChangeTier.minimal, ""),    // capped +20% rounds back to the pump rate
            (0.08, 0.096, 0.05, 0.08, ChangeTier.minimal, ""),   // no increment fits; the pump rate is kept
            (1.0, 1.08, 0.05, 1.1, ChangeTier.notable, "△"),     // +8% rounds up to +10%
            (1.0, 0.89, 0.05, 0.9, ChangeTier.minimal, ""),      // −11% rounds to −10%
            (0.15, 0.18, 0.025, 0.175, ChangeTier.notable, "△"), // a finer increment keeps part of the change
        ] as [(Double, Double, Double, Double, ChangeTier, String)]
    )
    func tierDescribesFinalRate(
        _ pump: Double,
        _ tuned: Double,
        _ increment: Double,
        _ final: Double,
        _ tier: ChangeTier,
        _ flag: String
    ) throws {
        let rec = try recommendation(pump: pump, tuned: tuned)
        let hour = rec.basalHours[0]
        #expect(hour.roundedRate(toIncrement: increment) == final)
        // The unrounded rate falls in a different tier, so this case matters.
        #expect(ChangeTier.classify(pump: pump, tuned: hour.recommendedRate) != tier)
        #expect(hour.changeTier(increment: increment) == tier)
        #expect(hour.guardrailStatus(increment: increment) == .ok)
        if increment == BasalHourRecommendation.loopBasalIncrement {
            #expect(hour.changeTier == tier)
        }

        let json = try basalJSON(rec, increment: increment)
        let exported = try #require((json["basal"] as? [[String: Any]])?.first)
        #expect(exported["recommendedRounded"] as? Double == final)
        #expect(exported["changeTier"] as? String == tier.rawValue)
        #expect(exported["guardrailStatus"] as? String == "ok")

        let report = TuningReport.render(rec, basalIncrement: increment)
        let row = try #require(report.split(separator: "\n").first { $0.hasPrefix("00:00 ") })
        let columns = row.split(separator: " ")
        #expect(columns.count == (flag.isEmpty ? 4 : 5), "\(row)")
        #expect(Double(columns[3]) == final)
        #expect((columns.count == 5 ? String(columns[4]) : "") == flag)
    }

    @Test("guardrail status follows the increment actually used")
    func guardrailStatusDescribesFinalRate() throws {
        // 0.042 is clamped to Loop's 0.05 minimum. At 0.1 U/hr steps no rate
        // fits, so the pump rate is entered and is not at the limit.
        let hour = try recommendation(pump: 0.06, tuned: 0.042).basalHours[0]
        #expect(hour.guardrailStatus == .atLimit)
        #expect(hour.roundedRate() == 0.05)
        #expect(hour.guardrailStatus(increment: 0.05) == .atLimit)
        #expect(hour.roundedRate(toIncrement: 0.1) == 0.06)
        #expect(hour.guardrailStatus(increment: 0.1) == .ok)
        #expect(hour.changeTier(increment: 0.1) == .minimal)

        let json = try basalJSON(try recommendation(pump: 0.06, tuned: 0.042), increment: 0.1)
        let exported = try #require((json["basal"] as? [[String: Any]])?.first)
        #expect(exported["guardrailStatus"] as? String == "ok")
    }

    @Test("saved runs report the tier of the final rate")
    func savedRunsDeriveTier() throws {
        let rec = try recommendation(
            pumpHourly: Array(repeating: 0.15, count: 24),
            tunedHourly: Array(repeating: 0.18, count: 24)
        )
        #expect(rec.basalHours.allSatisfy { $0.changeTier == .minimal })

        // A run saved before this change stored the tier of the unrounded rate.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(rec)) as? [String: Any])
        var hours = try #require(object["basalHours"] as? [[String: Any]])
        #expect(hours.allSatisfy { $0["changeTier"] as? String == "minimal" })
        hours = hours.map { hour in
            var hour = hour
            hour["changeTier"] = "large"
            return hour
        }
        object["basalHours"] = hours
        let legacy = try JSONDecoder().decode(
            TuningRecommendation.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.basalHours.allSatisfy { $0.changeTier == .minimal })

        // The run history headline compares the entered rates, not +20%.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let diagnostics = RunDiagnostics(
            glucoseCount: 0, doseCount: 0, carbCount: 0, windowStart: date, windowEnd: date,
            daySummaries: [], hourlyDeviation: [], meanAbsDeviationBefore: 0, meanAbsDeviationAfter: 0
        )
        let run = SavedRun(
            id: "run", createdAt: date, siteHost: "site", days: 1, insulinType: .novolog,
            recommendation: legacy, diagnostics: diagnostics
        )
        #expect(run.headline.hasPrefix("Basal 0% "))
    }

    @Test("the pipeline keeps a zero basal profile at zero")
    func pipelineKeepsZeroProfile() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = TherapyProfile(
            basalSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 0)]),
            sensitivitySchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 50)]),
            carbRatioSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 10)]),
            targetSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 100...110)]),
            timeZone: TimeZone(identifier: "UTC")!,
            glucoseUnit: .milligramsPerDeciliter,
            insulinType: .novolog
        )
        // Rising glucose with no insulin: basal deviations push the tuner up,
        // but the zero pump rate caps every hour at zero.
        let glucose = (0..<288).map { i in
            GlucoseSample(date: base.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: 110 + Double(i % 30))
        }
        let inputs = TuningInputs(
            profile: profile,
            glucose: glucose,
            doses: [],
            carbs: [],
            analysisStart: base,
            analysisEnd: glucose.last!.date
        )
        let rec = try TuningPipeline().run(inputs: inputs, configuration: TuningConfiguration(days: 1))
        #expect(rec.basalHours.allSatisfy { $0.recommendedRate == 0 && $0.roundedRate() == 0 })
        #expect(rec.roundedDailyBasal() == 0)
        #expect(rec.loopBasalSchedule() == [LoopBasalEntry(startMinutes: 0, rate: 0)])
    }

    private func basalJSON(_ rec: TuningRecommendation, increment: Double = 0.05) throws -> [String: Any] {
        let json = try RecommendationJSON.encode(rec, basalIncrement: increment)
        return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}
