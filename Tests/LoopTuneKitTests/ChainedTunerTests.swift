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
        let windows = ChainedTuner.dayWindows(from: start, to: end, timeZone: tz)
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
        // Day 1 has data; day 2 is empty; day 3 has data.
        var glucose: [GlucoseSample] = []
        for i in 0..<288 {
            glucose.append(GlucoseSample(date: base.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: 120))
        }
        for i in 0..<288 {
            glucose.append(GlucoseSample(date: base.addingTimeInterval(Double(2 * 288 + i) * 300), milligramsPerDeciliter: 120))
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
