import Testing
import Foundation
@testable import LoopTuneKit

/// Blocks without sufficient evidence of their own keep the pump value and
/// offer an alternative interpolated from evidence-backed blocks (ADR 0011).
@Suite("No-evidence interpolation")
struct NoEvidenceInterpolationTests {
    private let hour = 3600

    private func block(_ start: Int, pump: Double, tuned: Double? = nil, evidence: Int = 0) -> ScheduleTuningOutput {
        ScheduleTuningOutput(
            secondsSinceMidnight: start,
            // An untuned block's output value is what chained replay carried
            // forward. A historical 100 here must never reach the result.
            tunedValue: tuned ?? 100,
            pumpValue: pump,
            untuned: tuned == nil,
            evidenceCount: tuned == nil ? evidence : 12
        )
    }

    private func recommendation(
        sensitivity: [ScheduleTuningOutput] = [ScheduleTuningOutput(secondsSinceMidnight: 0, tunedValue: 40, pumpValue: 40, untuned: false)],
        carbRatio: [ScheduleTuningOutput] = [ScheduleTuningOutput(secondsSinceMidnight: 0, tunedValue: 10, pumpValue: 10, untuned: false)],
        tunedBasal: [Double] = Array(repeating: 1.0, count: 24),
        pumpBasal: [Double] = Array(repeating: 1.0, count: 24),
        untunedBasal: [Bool] = Array(repeating: false, count: 24)
    ) throws -> TuningRecommendation {
        let output = try TuningOutput(
            tunedBasalHourly: tunedBasal,
            pumpBasalHourly: pumpBasal,
            untunedBasalHours: untunedBasal,
            sensitivitySchedule: sensitivity,
            carbRatioSchedule: carbRatio,
            categoryCounts: [:],
            totalSamples: 100,
            basalSampleCountByHour: untunedBasal.map { $0 ? 0 : 12 }
        )
        return try TuningRecommendation(from: output, daysAnalyzed: 1)
    }

    // MARK: - The rule

    @Test("a block between two evidence-backed neighbours is weighted by midpoint distance")
    func betweenNeighbours() throws {
        // Midpoints: 02:00, 06:00, 14:00, 22:00. The 04:00 block is 4 h from
        // the 00:00 block and 8 h from the 08:00 block.
        let rec = try recommendation(sensitivity: [
            block(0, pump: 40, tuned: 44),
            block(4 * hour, pump: 40, evidence: 3),
            block(8 * hour, pump: 40, tuned: 48),
            block(20 * hour, pump: 40, tuned: 40),
        ])
        let entry = rec.sensitivitySchedule[1]
        #expect(entry.evidenceStatus == .insufficientData)
        #expect(entry.untuned)
        // The block itself recommends nothing new: the pump value, unchanged.
        #expect(entry.parameter.recommendedValue == 40)
        #expect(entry.parameter.rawTunedValue == 40)
        #expect(entry.parameter.changeTier == .minimal)
        #expect(entry.evidenceDescription("5-min intervals") == "3 5-min intervals")

        let evidence = try #require(entry.insufficientEvidence)
        let alternative = try #require(evidence.interpolated)
        // (44 × 8 + 48 × 4) / 12
        #expect(alternative.recommendedValue == 45.333)
        #expect(alternative.pumpValue == 40)
        #expect(alternative.changeTier == .notable)
        #expect(evidence.sources == [0, 8 * hour])
        #expect(evidence.sourceTimes == ["00:00", "08:00"])
        #expect(evidence.note == "Not enough data of its own. Interpolated from 00:00 and 08:00, the nearest blocks with enough data.")

        // Evidence-backed blocks are unaffected.
        #expect(rec.sensitivitySchedule[0].evidenceStatus == .tuned)
        #expect(rec.sensitivitySchedule[0].insufficientEvidence == nil)
        #expect(rec.sensitivitySchedule[0].parameter.recommendedValue == 44)
        // The daily summary averages the pump value for the insufficient block.
        #expect(abs(rec.sensitivity.recommendedValue - (44 * 4 + 40 * 4 + 48 * 12 + 40 * 4) / 24.0) < 1e-9)
        #expect(rec.sensitivity.rawTunedValue == rec.sensitivity.recommendedValue)
        #expect(rec.insufficientData == InsufficientDataSummary(basalHours: 0, sensitivityBlocks: 1, carbRatioBlocks: 0))
    }

    @Test("with one evidence-backed block, every other block takes its value within its own caps")
    func oneSided() throws {
        let rec = try recommendation(sensitivity: [
            block(0, pump: 40),
            block(6 * hour, pump: 40),
            block(12 * hour, pump: 40, tuned: 48),
            block(18 * hour, pump: 30),
        ])
        for index in [0, 1] {
            let evidence = try #require(rec.sensitivitySchedule[index].insufficientEvidence)
            #expect(evidence.interpolated?.recommendedValue == 48)
            #expect(evidence.sources == [12 * hour])
            #expect(evidence.note == "Not enough data of its own. Interpolated from 12:00, the only block with enough data.")
        }
        // Pump 30 allows at most 30 / 0.7.
        let capped = try #require(rec.sensitivitySchedule[3].insufficientEvidence?.interpolated)
        #expect(capped.recommendedValue == 42.857)
        #expect(rec.sensitivitySchedule[3].parameter.recommendedValue == 30)
    }

    @Test("interpolation wraps around midnight")
    func wrapsAtMidnight() throws {
        let rec = try recommendation(
            sensitivity: [
                block(0, pump: 40),
                block(6 * hour, pump: 40, tuned: 44),
                block(12 * hour, pump: 40, tuned: 50),
                block(18 * hour, pump: 40),
            ],
            tunedBasal: [1.0, 0.95] + Array(repeating: 1.0, count: 20) + [1.1, 1.0],
            untunedBasal: [true] + Array(repeating: false, count: 22) + [true]
        )
        // 18:00 (midpoint 21:00) lies 6 h after 12:00 and 12 h before 06:00
        // on the next day; 00:00 (midpoint 03:00) the reverse.
        let evening = try #require(rec.sensitivitySchedule[3].insufficientEvidence)
        #expect(evening.interpolated?.recommendedValue == 48)
        #expect(evening.sources == [12 * hour, 6 * hour])
        let night = try #require(rec.sensitivitySchedule[0].insufficientEvidence)
        #expect(night.interpolated?.recommendedValue == 46)
        #expect(night.sources == [12 * hour, 6 * hour])

        // Basal hours 23 and 00 lie between 22:00 (1.1) and 01:00 (0.95).
        let hour23 = rec.basalHours[23]
        #expect(hour23.insufficientEvidence?.interpolated == 1.05)
        #expect(hour23.insufficientEvidence?.sources == [22 * hour, hour])
        let hour0 = rec.basalHours[0]
        #expect(hour0.insufficientEvidence?.interpolated == 1.0)
        #expect(hour0.insufficientEvidence?.sources == [22 * hour, hour])
    }

    @Test("without evidence anywhere, or in a single-block schedule, only the pump value is offered")
    func noEvidence() throws {
        let rec = try recommendation(
            sensitivity: [block(0, pump: 40), block(12 * hour, pump: 45)],
            carbRatio: [block(0, pump: 10)],
            pumpBasal: Array(repeating: 0.8, count: 24),
            untunedBasal: Array(repeating: true, count: 24)
        )
        for entry in rec.sensitivitySchedule + rec.carbRatioSchedule {
            #expect(entry.evidenceStatus == .insufficientData)
            #expect(entry.parameter.recommendedValue == entry.parameter.pumpValue)
            #expect(entry.insufficientEvidence?.interpolated == nil)
            #expect(entry.insufficientEvidence?.sources == [])
            #expect(entry.insufficientEvidence?.note == "Not enough data of its own, and no block had enough data to interpolate from. Only the pump value is shown.")
        }
        for hour in rec.basalHours {
            #expect(hour.evidenceStatus == .insufficientData)
            #expect(hour.recommendedRate == 0.8)
            #expect(hour.roundedRate() == 0.8)
            #expect(hour.interpolatedRoundedRate() == nil)
        }
        #expect(rec.insufficientData.description == "24 basal hours, 2 ISF blocks, 1 carb-ratio block")
    }

    @Test("a scalar carb ratio without evidence offers only the pump value even when ISF has evidence")
    func scalarParameter() throws {
        let rec = try recommendation(
            sensitivity: [block(0, pump: 40, tuned: 44), block(12 * hour, pump: 40, tuned: 46)],
            carbRatio: [block(0, pump: 10)]
        )
        let carbRatio = rec.carbRatioSchedule[0]
        #expect(carbRatio.parameter.recommendedValue == 10)
        #expect(carbRatio.insufficientEvidence == InsufficientEvidence(interpolated: nil, sources: []))
        #expect(rec.carbRatio.recommendedValue == 10)
        #expect(rec.carbRatio.changeTier == .minimal)
    }

    // MARK: - Limits

    @Test("caps, guardrails, and basal rounding apply to the interpolated value")
    func limitsApply() throws {
        // ISF 360 and 420 neighbours interpolate to 390 for a block whose
        // pump is 450, inside its caps and Loop's recommended range. With
        // neighbours at 450 and 420, 435 is outside the recommended range.
        let isf = try recommendation(sensitivity: [
            block(0, pump: 360, tuned: 360),
            block(8 * hour, pump: 450),
            block(16 * hour, pump: 420, tuned: 420),
        ])
        let isfAlternative = try #require(isf.sensitivitySchedule[1].insufficientEvidence?.interpolated)
        #expect(isfAlternative.recommendedValue == 390)
        #expect(isfAlternative.guardrailStatus == .ok)
        let high = try recommendation(sensitivity: [
            block(0, pump: 450, tuned: 450),
            block(8 * hour, pump: 450),
            block(16 * hour, pump: 450, tuned: 420),
        ])
        #expect(high.sensitivitySchedule[1].insufficientEvidence?.interpolated?.guardrailStatus == .outsideRecommended)

        // Carb ratio: neighbours at 2.0 interpolate to 2.0, the pump-relative
        // cap for pump 1.5 lowers it to 1.8, and Loop's absolute minimum
        // raises it back to 2.0.
        let carbRatio = try recommendation(carbRatio: [
            block(0, pump: 2, tuned: 2),
            block(8 * hour, pump: 1.5),
            block(16 * hour, pump: 2, tuned: 2),
        ])
        let crAlternative = try #require(carbRatio.carbRatioSchedule[1].insufficientEvidence?.interpolated)
        #expect(crAlternative.rawTunedValue == 1.8)
        #expect(crAlternative.recommendedValue == 2)
        #expect(crAlternative.guardrailStatus == .atLimit)

        // Basal: hour 3 (pump 1.0) between 1.8 and 1.68 is capped at 1.2.
        // Hour 7 (pump 1.0) at a third of the way from 1.0 to 1.1 is 1.033,
        // which rounds to 1.05.
        var tuned = Array(repeating: 1.0, count: 24)
        var pump = Array(repeating: 1.0, count: 24)
        var untuned = Array(repeating: false, count: 24)
        (tuned[2], pump[2]) = (1.8, 1.5)
        untuned[3] = true
        (tuned[4], pump[4]) = (1.68, 1.4)
        untuned[7] = true
        untuned[8] = true
        tuned[9] = 1.1
        let basal = try recommendation(tunedBasal: tuned, pumpBasal: pump, untunedBasal: untuned)
        let capped = basal.basalHours[3]
        #expect(capped.insufficientEvidence?.interpolated == 1.2)
        #expect(capped.interpolatedRoundedRate() == 1.2)
        #expect(capped.recommendedRate == 1.0)
        #expect(capped.roundedRate() == 1.0)
        #expect(capped.changeTier == .minimal)
        let rounded = basal.basalHours[7]
        #expect(rounded.insufficientEvidence?.interpolated == 1.033)
        #expect(rounded.interpolatedRoundedRate() == 1.05)
        #expect(rounded.interpolatedRoundedRate(toIncrement: 0.025) == 1.025)
        #expect(rounded.interpolatedGuardrailStatus() == .ok)
        #expect(basal.basalHours[8].insufficientEvidence?.interpolated == 1.067)
    }

    @Test("an hour with insufficient data keeps the exact pump rate, even off the increment grid")
    func pumpRateKept() {
        let hour = BasalHourRecommendation(hour: 5, pumpRate: 0.975, interpolatedRate: 1.0, sources: [4 * 3600, 6 * 3600])
        #expect(hour.roundedRate() == 0.975)
        #expect(hour.changeTier == .minimal)
        #expect(hour.interpolatedRoundedRate() == 1.0)
    }

    // MARK: - Library pipeline

    @Test("the pipeline returns pump rates and interpolated alternatives for hours without basal evidence")
    func pipelinePartialBasalCoverage() throws {
        // 2023-11-13 00:00 UTC. CGM covers 00:00 to 12:00 only, so deviations
        // in hours 0–11 inform basal hours 21–23 and 0–10.
        let base = Date(timeIntervalSince1970: 1_699_833_600)
        let utc = TimeZone(identifier: "UTC")!
        let profile = TherapyProfile(
            basalSchedule: try DailySchedule(entries: [
                .init(secondsSinceMidnight: 0, value: 1.0),
                .init(secondsSinceMidnight: 12 * 3600, value: 0.8),
            ]),
            sensitivitySchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 40)]),
            carbRatioSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 10)]),
            targetSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 100...110)]),
            timeZone: utc,
            glucoseUnit: .milligramsPerDeciliter,
            insulinType: .novolog
        )
        let glucose = (0..<(12 * 12)).map { index in
            GlucoseSample(date: base.addingTimeInterval(Double(index) * 300), milligramsPerDeciliter: 115)
        }
        let rec = try TuningPipeline().run(
            inputs: TuningInputs(
                profile: profile,
                glucose: glucose,
                doses: [],
                carbs: [],
                analysisStart: base,
                analysisEnd: base.addingTimeInterval(86_400)
            ),
            configuration: TuningConfiguration(days: 1)
        )

        let insufficient = rec.basalHours.filter { $0.evidenceStatus == .insufficientData }.map(\.hour)
        #expect(insufficient == Array(11...20))
        // Flat glucose supports the pump rates where there is evidence.
        #expect(rec.basalHours[10].roundedRate() == 1.0)
        #expect(rec.basalHours[21].roundedRate() == 0.8)
        for hour in insufficient {
            let entry = rec.basalHours[hour]
            #expect(entry.sampleCount == 0)
            #expect(entry.recommendedRate == entry.pumpRate)
            #expect(entry.roundedRate() == entry.pumpRate)
            #expect(entry.insufficientEvidence?.sources == [10 * 3600, 21 * 3600])
        }
        // Hour 11 (pump 1.0): (1.0 × 10 + 0.8 × 1) / 11 = 0.982 → 1.0.
        #expect(rec.basalHours[11].insufficientEvidence?.interpolated == 0.982)
        #expect(rec.basalHours[11].interpolatedRoundedRate() == 1.0)
        // Hour 15 (pump 0.8): (1.0 × 6 + 0.8 × 5) / 11 = 0.909 → 0.9.
        #expect(rec.basalHours[15].insufficientEvidence?.interpolated == 0.909)
        #expect(rec.basalHours[15].interpolatedRoundedRate() == 0.9)
        #expect(rec.basalHours[15].interpolatedChangeTier() == .notable)

        // The Loop schedule keeps pump rates and marks the hours.
        let entries = rec.loopBasalSchedule()
        #expect(entries.first == LoopBasalEntry(startMinutes: 0, rate: 1.0))
        let marked = entries.filter { $0.evidenceStatus == .insufficientData }
        #expect(marked.map(\.startMinutes).first == 11 * 60)
        #expect(marked.allSatisfy { $0.insufficientEvidence?.sources == [10 * 3600, 21 * 3600] })
        #expect(entries.last == LoopBasalEntry(startMinutes: 21 * 60, rate: 0.8))
    }

    // MARK: - Outputs

    private func mixedRecommendation() throws -> TuningRecommendation {
        var untuned = Array(repeating: false, count: 24)
        untuned[3] = true
        untuned[4] = true
        var tuned = Array(repeating: 1.0, count: 24)
        tuned[5] = 1.3
        return try recommendation(
            sensitivity: [
                block(0, pump: 40, tuned: 44),
                block(4 * hour, pump: 40, evidence: 3),
                block(8 * hour, pump: 40, tuned: 48),
                block(20 * hour, pump: 40, tuned: 40),
            ],
            carbRatio: [block(0, pump: 10)],
            tunedBasal: tuned,
            pumpBasal: Array(repeating: 1.1, count: 24),
            untunedBasal: untuned
        )
    }

    @Test("the text report shows both values and the source for each insufficient block")
    func report() throws {
        let text = TuningReport.render(try mixedRecommendation())
        #expect(text.contains("⚠ Insufficient data: 2 basal hours, 1 ISF block, 1 carb-ratio block."))
        #expect(text.contains("04:00   40.0          —             3 5-min intervals  insufficient data"))
        #expect(text.contains("        Choose: pump 40.0 or interpolated 45.3 (+13% relative to pump, △)."))
        #expect(text.contains("        Not enough data of its own. Interpolated from 00:00 and 08:00, the nearest blocks with enough data."))
        #expect(text.contains("Carb Ratio            10.0 g/U      —             insufficient data; see schedule below"))
        #expect(text.contains("Carb Ratio schedule [g/U]"))
        #expect(text.contains("        Pump 10.0 only."))
        #expect(text.contains("Insulin Sensitivity   40.0 mg/dL/U  44.7          +12%  △  (1 of 4 blocks: insufficient data, pump value used)"))
        // Hour 3 lies between 1.0 at 02:00 and 1.3 at 05:00.
        #expect(text.contains("03:00   1.100       —           —         1             insufficient data: pump 1.10 or interpolated 1.10 (0% relative to pump, from 02:00 and 05:00)"))
        #expect(text.contains("04:00   1.100       —           —         1             insufficient data: pump 1.10 or interpolated 1.20 (+9% relative to pump, from 02:00 and 05:00)"))
        #expect(text.contains("Totals use the pump rate for hours with insufficient data."))
        #expect(text.contains("03:00   1.10 U/hr  ⚠ insufficient data: pump 1.10 or interpolated 1.10 U/hr from 02:00 and 05:00"))
        #expect(text.contains("04:00   1.10 U/hr  ⚠ insufficient data: pump 1.10 or interpolated 1.20 U/hr from 02:00 and 05:00"))
    }

    @Test("JSON adds both values for insufficient blocks and keeps the existing keys")
    func json() throws {
        let rec = try mixedRecommendation()
        let text = try RecommendationJSON.encode(rec)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])

        let schedule = try #require(root["sensitivitySchedule"] as? [[String: Any]])
        let tuned = schedule[0]
        #expect(tuned["evidenceStatus"] as? String == "tuned")
        #expect(tuned["interpolated"] == nil)
        #expect(tuned["note"] == nil)
        let insufficient = schedule[1]
        #expect(insufficient["evidenceStatus"] as? String == "insufficientData")
        #expect(insufficient["pump"] as? Double == 40)
        #expect(insufficient["recommended"] as? Double == 40)
        #expect(insufficient["changeTier"] as? String == "minimal")
        #expect(insufficient["untuned"] as? Bool == true)
        #expect(insufficient["note"] as? String == "Not enough data of its own. Interpolated from 00:00 and 08:00, the nearest blocks with enough data.")
        let alternative = try #require(insufficient["interpolated"] as? [String: Any])
        #expect(alternative["recommended"] as? Double == 45.333)
        #expect(alternative["changeTier"] as? String == "notable")
        #expect(alternative["from"] as? [String] == ["00:00", "08:00"])
        #expect(alternative["fromSecondsSinceMidnight"] as? [Int] == [0, 28_800])

        let carbRatio = try #require((root["carbRatioSchedule"] as? [[String: Any]])?.first)
        #expect(carbRatio["evidenceStatus"] as? String == "insufficientData")
        #expect(carbRatio["interpolated"] == nil)
        #expect((carbRatio["note"] as? String)?.contains("Only the pump value is shown.") == true)

        let basal = try #require(root["basal"] as? [[String: Any]])
        #expect(basal[2]["evidenceStatus"] as? String == "tuned")
        let hour4 = basal[4]
        #expect(hour4["evidenceStatus"] as? String == "insufficientData")
        #expect(hour4["recommendedRounded"] as? Double == 1.1)
        let basalAlternative = try #require(hour4["interpolated"] as? [String: Any])
        #expect(basalAlternative["recommended"] as? Double == 1.2)
        #expect(basalAlternative["recommendedRounded"] as? Double == 1.2)
        #expect(basalAlternative["fromHours"] as? [Int] == [2, 5])

        let loop = try #require(root["loopBasalSchedule"] as? [[String: Any]])
        #expect(loop.map { $0["time"] as? String } == ["00:00", "03:00", "04:00", "05:00", "06:00"])
        #expect(loop[0]["evidenceStatus"] as? String == "tuned")
        #expect(loop[0]["interpolatedRate"] == nil)
        #expect(loop[2]["rate"] as? Double == 1.1)
        #expect(loop[2]["evidenceStatus"] as? String == "insufficientData")
        #expect(loop[2]["interpolatedRate"] as? Double == 1.2)
        #expect(loop[2]["interpolatedFrom"] as? [String] == ["02:00", "05:00"])
    }

    // MARK: - Persistence

    @Test("saved runs round-trip the alternatives, and runs saved before them still load")
    func persistence() throws {
        let rec = try mixedRecommendation()
        let data = try JSONEncoder().encode(rec)
        #expect(try JSONDecoder().decode(TuningRecommendation.self, from: data) == rec)

        // A run saved before ADR 0011 has no `insufficientEvidence` keys and
        // keeps the value its version carried forward.
        var legacy = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["sensitivitySchedule", "carbRatioSchedule", "basalHours"] {
            legacy[key] = (legacy[key] as? [[String: Any]])?.map { entry in
                var entry = entry
                entry["insufficientEvidence"] = nil
                return entry
            }
        }
        var basalHours = try #require(legacy["basalHours"] as? [[String: Any]])
        basalHours[4]["recommendedRate"] = 1.013
        legacy["basalHours"] = basalHours
        let decoded = try JSONDecoder().decode(
            TuningRecommendation.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(decoded.sensitivitySchedule[1].evidenceStatus == .carriedForward)
        #expect(decoded.sensitivitySchedule[0].evidenceStatus == .tuned)
        #expect(decoded.basalHours[4].evidenceStatus == .carriedForward)
        #expect(decoded.basalHours[4].roundedRate() == 1.0)
        #expect(decoded.insufficientData.isEmpty)
        // Legacy runs render as before, without insufficient-data notes.
        let text = TuningReport.render(decoded)
        #expect(!text.contains("insufficient data"))
        #expect(text.contains("(no data)"))

        // Interpolation sources are shown as times, so they must be valid.
        var corrupt = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var schedule = try #require(corrupt["sensitivitySchedule"] as? [[String: Any]])
        var evidence = try #require(schedule[1]["insufficientEvidence"] as? [String: Any])
        evidence["sources"] = [0, 86_400]
        schedule[1]["insufficientEvidence"] = evidence
        corrupt["sensitivitySchedule"] = schedule
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TuningRecommendation.self, from: JSONSerialization.data(withJSONObject: corrupt))
        }
    }
}
