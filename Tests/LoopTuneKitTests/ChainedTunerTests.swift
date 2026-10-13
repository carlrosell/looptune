import Testing
import Foundation
@testable import LoopTuneKit

@Suite("ChainedTuner")
struct ChainedTunerTests {
    // 2023-11-13 00:00 UTC.
    private let base = Date(timeIntervalSince1970: 1_699_833_600)

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

    @Test("day windows cut at 04:00 local")
    func dayWindows() {
        let tz = TimeZone(identifier: "UTC")!
        // 3 full days starting at midnight: expect windows [00–04], [04–04]×2, [04–24].
        let start = base
        let end = base.addingTimeInterval(3 * 86_400)
        let windows = HistoricalReplay.dayWindows(from: start, to: end, timeZone: tz)
        #expect(windows.count == 4)
        #expect(windows.first?.start == start)
        #expect(windows.last?.end == end)
        // Interior boundaries land at 04:00.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        for window in windows.dropFirst() {
            #expect(cal.component(.hour, from: window.start) == 4)
        }
        // Contiguous tiling.
        for i in 1..<windows.count {
            #expect(windows[i].start == windows[i - 1].end)
        }
    }

    @Test("chained run compounds movement further than a single run, within pump caps")
    func chainingCompounds() throws {
        // Three days of glucose drifting upward with no insulin: persistent
        // positive basal deviations every day.
        let count = 3 * 288
        let glucose = (0..<count).map { i in
            GlucoseSample(date: base.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: 110 + Double(i % 24))
        }
        let inputs = TuningInputs(
            profile: try profile(),
            glucose: glucose, doses: [], carbs: [],
            analysisStart: base,
            analysisEnd: glucose.last!.date
        )

        let chained = try ChainedTuner().run(inputs: inputs)
        #expect(chained.daysTuned >= 3)
        #expect(chained.dailyISF.count == chained.daysTuned)

        // Single run over just the first day.
        let dayOneInputs = TuningInputs(
            profile: try profile(),
            glucose: Array(glucose.prefix(288)), doses: [], carbs: [],
            analysisStart: base,
            analysisEnd: glucose[287].date
        )
        let single = try TuningPipeline().run(inputs: dayOneInputs, configuration: TuningConfiguration(days: 1))

        let chainedTotal = chained.output.tunedBasalHourly.reduce(0, +)
        let singleTotal = single.tunedDailyBasal
        // Persistent upward drift: more chained days should move basal at least
        // as far as one day, and never past the pump cap.
        #expect(chainedTotal >= singleTotal - 1e-6)
        #expect(chained.output.tunedBasalHourly.allSatisfy { $0 <= 1.2 + 1e-9 })
        #expect(chained.output.tunedBasalHourly.allSatisfy { $0 >= 0.7 - 1e-9 })
    }

    @Test("caps stay anchored to the pump profile across many chained days")
    func capsAnchoredToPump() throws {
        // Six days of strong upward drift: without pump-anchored caps the basal
        // would compound past 1.2×; with them it must not.
        let count = 6 * 288
        let glucose = (0..<count).map { i in
            GlucoseSample(date: base.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: 120 + Double(i % 40))
        }
        let inputs = TuningInputs(
            profile: try profile(),
            glucose: glucose, doses: [], carbs: [],
            analysisStart: base,
            analysisEnd: glucose.last!.date
        )
        let chained = try ChainedTuner().run(inputs: inputs)
        #expect(chained.output.tunedBasalHourly.allSatisfy { $0 <= 1.2 + 1e-9 })
        // ISF caps are inverted: [pump/1.2, pump/0.7].
        #expect(chained.output.tunedISF >= 50 / 1.2 - 1e-9)
        #expect(chained.output.tunedISF <= 50 / 0.7 + 1e-9)
    }

    @Test("days with no data increment daysMissing for every hour")
    func missingDays() throws {
        // Data until 04:00 on day 2, none in the window from 04:00 on day 2 to
        // 04:00 on day 3, then data again. Flat glucose is basal evidence that
        // supports the current rates, so only the empty window is missing.
        var glucose: [GlucoseSample] = []
        for i in 0..<(28 * 12) {
            glucose.append(GlucoseSample(date: base.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: 120))
        }
        for i in (52 * 12)..<(72 * 12) {
            glucose.append(GlucoseSample(date: base.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: 120))
        }
        let inputs = TuningInputs(
            profile: try profile(),
            glucose: glucose, doses: [], carbs: [],
            analysisStart: base,
            analysisEnd: base.addingTimeInterval(3 * 86_400)
        )
        let chained = try ChainedTuner().run(inputs: inputs)
        // At least one full window had no usable data.
        #expect(chained.daysMissingByHour.allSatisfy { $0 >= 1 })
    }

    @Test("pipeline uses chaining for multi-day windows and surfaces daysMissing")
    func pipelineIntegration() throws {
        let count = 2 * 288
        let glucose = (0..<count).map { i in
            GlucoseSample(date: base.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: 115)
        }
        let inputs = TuningInputs(
            profile: try profile(),
            glucose: glucose, doses: [], carbs: [],
            analysisStart: base,
            analysisEnd: glucose.last!.date
        )
        let rec = try TuningPipeline().run(inputs: inputs, configuration: TuningConfiguration(days: 2))
        #expect(rec.daysTuned != nil)
        #expect(rec.basalHours.count == 24)
        // daysMissing values are within the number of windows.
        #expect(rec.basalHours.allSatisfy { $0.daysMissing >= 0 && $0.daysMissing <= 4 })
    }
}

@Suite("Chained tuning resets at a therapy change")
struct ChainedTherapyResetTests {
    // 2023-11-13 04:00 UTC: the audit window starts at a day boundary.
    private let start = Date(timeIntervalSince1970: 1_699_833_600 + 4 * 3600)

    private func profile(activeFrom: Date, isf: Double, carbRatio: Double) throws -> TherapyProfile {
        TherapyProfile(
            basalSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 1.0)]),
            sensitivitySchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: isf)]),
            carbRatioSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: carbRatio)]),
            targetSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 100...110)]),
            timeZone: TimeZone(identifier: "UTC")!,
            glucoseUnit: .milligramsPerDeciliter,
            activeFrom: activeFrom,
            insulinType: .novolog
        )
    }

    /// The CORE-04 audit scenario: old ISF 100 / CR 30, current ISF 40 / CR 10
    /// activated `changeHour` hours into a 24-hour window, flat five-minute CGM
    /// through hour `cgmHours`, no doses or carbs.
    private func inputs(changeHour: Double, cgmHours: Double) throws -> TuningInputs {
        let changeDate = start.addingTimeInterval(changeHour * 3600)
        let old = try profile(activeFrom: start.addingTimeInterval(-86_400), isf: 100, carbRatio: 30)
        let new = try profile(activeFrom: changeDate, isf: 40, carbRatio: 10)
        let glucose = (0...Int(cgmHours * 12)).map { i in
            GlucoseSample(date: start.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: 120)
        }
        return TuningInputs(
            profile: new,
            profileHistory: ProfileHistory(timeline: [old, new], current: new),
            glucose: glucose, doses: [], carbs: [],
            analysisStart: start,
            analysisEnd: start.addingTimeInterval(86_400)
        )
    }

    @Test("a late change with no later CGM keeps no output or evidence from the old settings")
    func lateChangeWithoutCGM() throws {
        let inputs = try inputs(changeHour: 23, cgmHours: 22)
        let result = try ChainedTuner().run(inputs: inputs)

        #expect(result.settingsChanges == [start.addingTimeInterval(23 * 3600)])
        // The final settings are reported unchanged and untuned, not the old
        // ISF 100 / CR 30 tuned under the previous epoch.
        #expect(result.output.tunedISF == 40)
        #expect(result.output.tunedCarbRatio == 10)
        #expect(result.output.totalSamples == 0)
        #expect(result.output.categoryCounts.isEmpty)
        #expect(result.output.basalSampleCountByHour.allSatisfy { $0 == 0 })
        #expect(result.output.untunedBasalHours.allSatisfy { $0 })
        #expect(result.output.sensitivitySchedule.allSatisfy { $0.untuned && $0.evidenceCount == 0 && $0.daysMissing == 1 })
        #expect(result.output.carbRatioSchedule.allSatisfy { $0.untuned && $0.evidenceCount == 0 && $0.daysMissing == 1 })
        #expect(result.daysMissingByHour.allSatisfy { $0 == 1 })
        #expect(result.daysTuned == 0)
        #expect(result.dailyISF.isEmpty)
        #expect(result.dailyCarbRatio.isEmpty)
    }

    @Test("the pipeline reports insufficient data for a late change with no later CGM")
    func lateChangePipelineOutcome() throws {
        #expect(throws: TuningPipeline.PipelineError.insufficientUsableData(minimum: 12, actual: 0)) {
            _ = try TuningPipeline().run(
                inputs: try inputs(changeHour: 23, cgmHours: 22),
                configuration: TuningConfiguration(days: 1)
            )
        }
    }

    @Test("enough evidence after a change produces output from the new settings alone")
    func adequatePostChangeEvidence() throws {
        let result = try ChainedTuner().run(inputs: try inputs(changeHour: 12, cgmHours: 24))

        // Tuning only the post-change period from the new settings, with no
        // history, must give the same recommendation and evidence.
        let full = try inputs(changeHour: 12, cgmHours: 24)
        let postChangeOnly = try ChainedTuner().run(inputs: TuningInputs(
            profile: full.profile,
            glucose: full.glucose, doses: [], carbs: [],
            analysisStart: start.addingTimeInterval(12 * 3600),
            analysisEnd: full.analysisEnd
        ))

        #expect(result.settingsChanges == [start.addingTimeInterval(12 * 3600)])
        #expect(result.output.totalSamples > 0)
        #expect(result.output.totalSamples <= 12 * 12)
        #expect(result.output.pumpISF == 40)
        #expect(result.output.pumpCarbRatio == 10)
        #expect(result.output == postChangeOnly.output)
        #expect(result.daysMissingByHour == postChangeOnly.daysMissingByHour)
        #expect(result.daysTuned == 1)
        #expect(result.dailyISF == postChangeOnly.dailyISF)
        #expect(result.dailyCarbRatio == postChangeOnly.dailyCarbRatio)

        let recommendation = try TuningPipeline().run(inputs: full, configuration: TuningConfiguration(days: 1))
        #expect(recommendation.settingsChanges == [start.addingTimeInterval(12 * 3600)])
        #expect(recommendation.daysTuned == 1)
    }
}
