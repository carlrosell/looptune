import Testing
import Foundation
@testable import LoopTuneKit

@Suite("ProfileHistory")
struct ProfileHistoryTests {
    private func profile(activeFrom: Date?, basal: Double, isf: Double = 50, cr: Double = 10, target: ClosedRange<Double> = 100...110) throws -> TherapyProfile {
        TherapyProfile(
            basalSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: basal)]),
            sensitivitySchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: isf)]),
            carbRatioSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: cr)]),
            targetSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: target)]),
            timeZone: TimeZone(identifier: "UTC")!,
            glucoseUnit: .milligramsPerDeciliter,
            activeFrom: activeFrom
        )
    }

    private let day0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("activeProfile picks the latest profile activated at or before a date")
    func activeProfileLookup() throws {
        let old = try profile(activeFrom: day0, basal: 1.0)
        let new = try profile(activeFrom: day0.addingTimeInterval(5 * 86_400), basal: 1.3)
        let history = ProfileHistory(timeline: [new, old], current: new)

        // Before any profile → falls back to earliest.
        #expect(history.activeProfile(at: day0.addingTimeInterval(-86_400)).basalSchedule.value(atSecondsSinceMidnight: 0) == 1.0)
        // Between → old still active.
        #expect(history.activeProfile(at: day0.addingTimeInterval(2 * 86_400)).basalSchedule.value(atSecondsSinceMidnight: 0) == 1.0)
        // After the change → new.
        #expect(history.activeProfile(at: day0.addingTimeInterval(6 * 86_400)).basalSchedule.value(atSecondsSinceMidnight: 0) == 1.3)
    }

    @Test("timeline sorts ascending regardless of input order")
    func timelineSorted() throws {
        let a = try profile(activeFrom: day0, basal: 1.0)
        let b = try profile(activeFrom: day0.addingTimeInterval(86_400), basal: 1.1)
        let c = try profile(activeFrom: day0.addingTimeInterval(2 * 86_400), basal: 1.2)
        let history = ProfileHistory(timeline: [c, a, b], current: c)
        #expect(history.timeline.map { $0.activeFrom } == [a.activeFrom, b.activeFrom, c.activeFrom])
    }

    @Test("hasSameTherapySettings ignores non-tuning fields")
    func therapyEquality() throws {
        let base = try profile(activeFrom: day0, basal: 1.0, isf: 50, cr: 10, target: 100...110)
        // Same basal/ISF/CR but a different target → still the same therapy for tuning.
        let differentTarget = try profile(activeFrom: day0, basal: 1.0, isf: 50, cr: 10, target: 90...100)
        #expect(base.hasSameTherapySettings(as: differentTarget))
        // Different basal → a real therapy change.
        let differentBasal = try profile(activeFrom: day0, basal: 1.2, isf: 50, cr: 10)
        #expect(!base.hasSameTherapySettings(as: differentBasal))
    }

    @Test("target-only profile uploads do not split a tuning window")
    func nonTherapyUploadDoesNotSplit() throws {
        let targetChange = day0.addingTimeInterval(3600)
        let before = try profile(
            activeFrom: day0,
            basal: 1,
            target: 100...110
        )
        let after = try profile(
            activeFrom: targetChange,
            basal: 1,
            target: 90...100
        )
        let window = DateInterval(
            start: day0,
            end: day0.addingTimeInterval(2 * 3600)
        )
        let segments = ChainedTuner.profileSegments(
            for: window,
            history: ProfileHistory(timeline: [before, after], current: after)
        )
        #expect(segments == [window])
    }

    @Test("makeHistory parses documents newest-first and drops undated from the timeline")
    func makeHistory() throws {
        let newer = #"{"defaultProfile":"Default","units":"mg/dL","startDate":"2023-11-20T00:00:00Z","store":{"Default":{"timezone":"UTC","basal":[{"timeAsSeconds":0,"value":1.3}],"sens":[{"timeAsSeconds":0,"value":50}],"carbratio":[{"timeAsSeconds":0,"value":10}],"target_low":[{"timeAsSeconds":0,"value":100}],"target_high":[{"timeAsSeconds":0,"value":110}]}}}"#
        let older = #"{"defaultProfile":"Default","units":"mg/dL","startDate":"2023-11-10T00:00:00Z","store":{"Default":{"timezone":"UTC","basal":[{"timeAsSeconds":0,"value":1.0}],"sens":[{"timeAsSeconds":0,"value":50}],"carbratio":[{"timeAsSeconds":0,"value":10}],"target_low":[{"timeAsSeconds":0,"value":100}],"target_high":[{"timeAsSeconds":0,"value":110}]}}}"#
        let docs = try [newer, older].map { try JSONDecoder().decode(NSProfileDocument.self, from: Data($0.utf8)) }
        let history = try ProfileIngest.makeHistory(from: docs)
        // Current is the newest document.
        #expect(history.current.basalSchedule.value(atSecondsSinceMidnight: 0) == 1.3)
        #expect(history.timeline.count == 2)
    }

    @Test("makeHistory rejects a malformed historical profile instead of silently dropping it")
    func makeHistoryRejectsMalformedHistory() throws {
        let valid = #"{"defaultProfile":"Default","units":"mg/dL","startDate":"2023-11-20T00:00:00Z","store":{"Default":{"timezone":"UTC","basal":[{"timeAsSeconds":0,"value":1.3}],"sens":[{"timeAsSeconds":0,"value":50}],"carbratio":[{"timeAsSeconds":0,"value":10}],"target_low":[{"timeAsSeconds":0,"value":100}],"target_high":[{"timeAsSeconds":0,"value":110}]}}}"#
        let invalid = #"{"defaultProfile":"Default","units":"mg/dL","startDate":"2023-11-10T00:00:00Z","store":{"Default":{"timezone":"UTC","basal":[{"timeAsSeconds":0,"value":-1}],"sens":[{"timeAsSeconds":0,"value":50}],"carbratio":[{"timeAsSeconds":0,"value":10}],"target_low":[{"timeAsSeconds":0,"value":100}],"target_high":[{"timeAsSeconds":0,"value":110}]}}}"#
        let docs = try [valid, invalid].map {
            try JSONDecoder().decode(NSProfileDocument.self, from: Data($0.utf8))
        }
        #expect(throws: ProfileIngest.IngestError.invalidValue("basal")) {
            _ = try ProfileIngest.makeHistory(from: docs)
        }
    }

    @Test("configured insulin type fills every historical profile without replacing explicit types")
    func defaultInsulinTypeAcrossHistory() throws {
        let old = try profile(activeFrom: day0, basal: 1.0)
        var new = try profile(activeFrom: day0.addingTimeInterval(86_400), basal: 1.1)
        new.insulinType = .humalog
        let updated = ProfileHistory(timeline: [old, new], current: new)
            .applyingDefaultInsulinType(.fiasp)

        #expect(updated.timeline[0].insulinType == .fiasp)
        #expect(updated.timeline[1].insulinType == .humalog)
        #expect(updated.current.insulinType == .humalog)
        // Confirm value semantics: the source profile was not mutated.
        #expect(old.insulinType == nil)
    }
}

@Suite("Chained tuning across a settings change")
struct ChainedProfileChangeTests {
    private let base = Date(timeIntervalSince1970: 1_699_833_600) // 2023-11-13 00:00 UTC

    private func profile(activeFrom: Date?, basal: Double) throws -> TherapyProfile {
        TherapyProfile(
            basalSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: basal)]),
            sensitivitySchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 50)]),
            carbRatioSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 10)]),
            targetSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 100...110)]),
            timeZone: TimeZone(identifier: "UTC")!,
            glucoseUnit: .milligramsPerDeciliter,
            activeFrom: activeFrom,
            insulinType: .novolog
        )
    }

    @Test("a mid-window settings change restarts the tuning iteration from the applied profile")
    func settingsChangeResetsBaseline() throws {
        // 4 days of steady-ish glucose; the user raises basal from 0.8 to 1.2
        // at the start of day 3.
        let changeDate = base.addingTimeInterval(2 * 86_400)
        let old = try profile(activeFrom: base, basal: 0.8)
        let new = try profile(activeFrom: changeDate, basal: 1.2)
        let history = ProfileHistory(timeline: [old, new], current: new)

        let count = 4 * 288
        let glucose = (0..<count).map { i in
            GlucoseSample(date: base.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: 120 + Double(i % 20))
        }
        let inputs = TuningInputs(
            profile: new,
            profileHistory: history,
            glucose: glucose, doses: [], carbs: [],
            analysisStart: base,
            analysisEnd: glucose.last!.date
        )

        let result = try ChainedTuner().run(inputs: inputs)
        // The change was detected.
        #expect(result.settingsChanges == [changeDate])
        // Caps stay anchored to the CURRENT (new) profile: basal within 0.7–1.2×1.2.
        #expect(result.output.pumpBasalHourly.allSatisfy { $0 == 1.2 })
        #expect(result.output.tunedBasalHourly.allSatisfy { $0 <= 1.2 * 1.2 + 1e-9 && $0 >= 1.2 * 0.7 - 1e-9 })
    }

    @Test("no history means no settings-change restarts")
    func noHistoryNoRestart() throws {
        let current = try profile(activeFrom: nil, basal: 1.0)
        let count = 2 * 288
        let glucose = (0..<count).map { i in
            GlucoseSample(date: base.addingTimeInterval(Double(i) * 300), milligramsPerDeciliter: 120)
        }
        let inputs = TuningInputs(
            profile: current, profileHistory: nil,
            glucose: glucose, doses: [], carbs: [],
            analysisStart: base, analysisEnd: glucose.last!.date
        )
        let result = try ChainedTuner().run(inputs: inputs)
        #expect(result.settingsChanges.isEmpty)
    }

    @Test("pipeline honors a profile change inside a one-day analysis")
    func oneDayPipelineUsesHistory() throws {
        let changeDate = base.addingTimeInterval(6 * 3600)
        let old = try profile(activeFrom: base, basal: 0.8)
        let new = try profile(activeFrom: changeDate, basal: 1.2)
        let glucose = (0..<144).map { index in
            GlucoseSample(
                date: base.addingTimeInterval(Double(index) * 300),
                milligramsPerDeciliter: 120 + Double(index % 12)
            )
        }
        let recommendation = try TuningPipeline().run(
            inputs: TuningInputs(
                profile: new,
                profileHistory: ProfileHistory(timeline: [old, new], current: new),
                glucose: glucose,
                doses: [],
                carbs: [],
                analysisStart: base,
                analysisEnd: glucose.last!.date
            ),
            configuration: TuningConfiguration(days: 1)
        )
        #expect(recommendation.settingsChanges == [changeDate])
        #expect(recommendation.daysTuned != nil)
    }
}
