import Testing
import Foundation
@testable import LoopTuneKit

/// The CORE-06 scenario: ISF 40 is replaced by ISF 80 at `activation`, an
/// input is logged one hour earlier, basal is unchanged, and CGM is flat.
struct ProfileChangeScenario {
    // 2023-11-13 04:00 UTC: the analysis starts at a day boundary.
    static let start = Date(timeIntervalSince1970: 1_699_833_600 + 4 * 3600)
    static let activation = start.addingTimeInterval(12 * 3600)
    static let preChange = activation.addingTimeInterval(-3600)

    static func profile(
        activeFrom: Date?,
        basal: Double = 1.0,
        isf: Double,
        carbRatio: Double = 10,
        target: ClosedRange<Double> = 100...110,
        insulinType: InsulinType = .novolog
    ) throws -> TherapyProfile {
        TherapyProfile(
            basalSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: basal)]),
            sensitivitySchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: isf)]),
            carbRatioSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: carbRatio)]),
            targetSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: target)]),
            timeZone: TimeZone(identifier: "UTC")!,
            glucoseUnit: .milligramsPerDeciliter,
            activeFrom: activeFrom,
            insulinType: insulinType
        )
    }

    static func old(basal: Double = 1.0) throws -> TherapyProfile {
        try profile(activeFrom: start.addingTimeInterval(-2 * 86_400), basal: basal, isf: 40)
    }

    static func new(basal: Double = 1.0) throws -> TherapyProfile {
        try profile(activeFrom: activation, basal: basal, isf: 80)
    }

    /// Flat CGM from twelve hours before the analysis start through its end.
    static let glucose: [GlucoseSample] = (-144...288).map {
        GlucoseSample(date: start.addingTimeInterval(Double($0) * 300), milligramsPerDeciliter: 120)
    }

    /// CGM rising 3 mg/dL per five minutes for four hours after a post-change
    /// meal, so carb-ratio tuning has usable meal evidence.
    static let glucoseRisingAfterMeal: [GlucoseSample] = glucose.map { sample in
        let rise = sample.date.timeIntervalSince(activation.addingTimeInterval(2 * 3600)) / 300
        return GlucoseSample(date: sample.date, milligramsPerDeciliter: 120 + 3 * min(max(rise, 0), 48))
    }

    static func bolus(_ units: Double, at date: Date = preChange) -> DoseRecord {
        DoseRecord(kind: .bolus(units: units), startDate: date, endDate: date)
    }

    static func meal(_ grams: Double, at date: Date = preChange) -> CarbRecord {
        CarbRecord(date: date, grams: grams)
    }
}

/// A pre-change input and its equivalent under the new settings. With the
/// same basal and carb ratio, 1 U at ISF 40 has the glucose effect of 0.5 U at
/// ISF 80, and 30 g at 4 mg/dL/g that of 15 g at 8 mg/dL/g.
enum PreChangeInput: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case bolus
    case meal

    var testDescription: String { rawValue }

    func doses(equivalentUnderNewSettings: Bool) -> [DoseRecord] {
        guard self == .bolus else { return [] }
        return [ProfileChangeScenario.bolus(equivalentUnderNewSettings ? 0.5 : 1)]
    }

    func carbs(equivalentUnderNewSettings: Bool) -> [CarbRecord] {
        guard self == .meal else { return [] }
        return [ProfileChangeScenario.meal(equivalentUnderNewSettings ? 15 : 30)]
    }
}

/// A settings change at the activation. Schedules it does not name keep the
/// same value on both sides.
enum SettingsChange: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case basal
    case sensitivity
    case carbRatio
    case basalAndSensitivity

    var testDescription: String { rawValue }

    var old: TherapyProfile {
        get throws {
            try ProfileChangeScenario.profile(
                activeFrom: ProfileChangeScenario.start.addingTimeInterval(-2 * 86_400),
                basal: 1,
                isf: 40,
                carbRatio: 10
            )
        }
    }

    var new: TherapyProfile {
        get throws {
            try ProfileChangeScenario.profile(
                activeFrom: ProfileChangeScenario.activation,
                basal: self == .basal || self == .basalAndSensitivity ? 2 : 1,
                isf: self == .sensitivity || self == .basalAndSensitivity ? 80 : 40,
                carbRatio: self == .carbRatio ? 20 : 10
            )
        }
    }
}

@Suite("Historical replay context")
struct HistoricalReplayTests {
    typealias Scenario = ProfileChangeScenario

    private func history(old: TherapyProfile, new: TherapyProfile) -> ProfileHistory {
        ProfileHistory(timeline: [old, new], current: new)
    }

    /// Replay the post-activation segment of the scenario window.
    private func replayAfterActivation(
        history: ProfileHistory,
        doses: [DoseRecord] = [],
        carbs: [CarbRecord] = [],
        candidate: TherapyProfile? = nil
    ) throws -> [DeviationSample] {
        let replay = HistoricalReplay(inputs: TuningInputs(
            profile: history.current,
            profileHistory: history,
            glucose: Scenario.glucose,
            doses: doses,
            carbs: carbs,
            analysisStart: Scenario.start,
            analysisEnd: Scenario.start.addingTimeInterval(86_400)
        ))
        let segments = replay.segmentsByDay().joined()
        let segment = try #require(segments.first { $0.interval.start == Scenario.activation })
        #expect(segment.settingsActivation == Scenario.activation)
        return try replay.replay(segment, candidate: candidate ?? segment.recorded).deviations
    }

    /// Replay the same post-activation interval with one profile throughout.
    private func replayWithSingleProfile(
        _ profile: TherapyProfile,
        doses: [DoseRecord] = [],
        carbs: [CarbRecord] = []
    ) throws -> [DeviationSample] {
        let trimmed = ReplayEngine.trimmedInputs(
            glucose: Scenario.glucose,
            doses: doses,
            carbs: carbs,
            analysisStart: Scenario.activation,
            analysisEnd: Scenario.start.addingTimeInterval(86_400)
        )
        return try ReplayEngine().computeDeviations(
            glucose: trimmed.glucose,
            doses: trimmed.doses,
            carbs: trimmed.carbs,
            profile: profile,
            analysisStart: Scenario.activation,
            analysisEnd: Scenario.start.addingTimeInterval(86_400)
        )
    }

    private func expectEqual(
        _ lhs: [DeviationSample],
        _ rhs: [DeviationSample],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(lhs.count == rhs.count, sourceLocation: sourceLocation)
        for (a, b) in zip(lhs, rhs) {
            #expect(a.date == b.date, sourceLocation: sourceLocation)
            #expect(abs(a.insulinEffect - b.insulinEffect) < 1e-9, sourceLocation: sourceLocation)
            #expect(abs(a.deviation - b.deviation) < 1e-9, sourceLocation: sourceLocation)
            #expect(abs(a.carbsOnBoard - b.carbsOnBoard) < 1e-9, sourceLocation: sourceLocation)
        }
    }

    @Test("a pre-change bolus keeps its recorded ISF after activation")
    func preChangeBolus() throws {
        let old = try Scenario.old()
        let new = try Scenario.new()
        let dose = Scenario.bolus(1)

        let historical = try replayAfterActivation(history: history(old: old, new: new), doses: [dose])
        let first = try #require(historical.first)
        #expect(first.date == Scenario.activation.addingTimeInterval(300))
        #expect(abs(first.insulinEffect - -1.076170) < 1e-6)

        // The audit baseline: one profile over the lookback doubles the effect.
        let reinterpreted = try replayWithSingleProfile(new, doses: [dose])
        #expect(abs(reinterpreted[0].insulinEffect - -2.152340) < 1e-6)
        expectEqual(historical, try replayWithSingleProfile(old, doses: [dose]))

        // A tuned candidate replaces the new settings, not the recorded ones.
        let tuned = try Scenario.profile(activeFrom: Scenario.activation, isf: 60)
        let withCandidate = try replayAfterActivation(
            history: history(old: old, new: new),
            doses: [dose],
            candidate: tuned
        )
        expectEqual(withCandidate, historical)
    }

    @Test("a pre-change temp basal is netted against its recorded basal and ISF")
    func preChangeTempBasal() throws {
        let old = try Scenario.old(basal: 1.0)
        let new = try Scenario.new(basal: 2.0)
        let temp = DoseRecord(
            kind: .tempBasal(unitsPerHour: 4),
            startDate: Scenario.activation.addingTimeInterval(-90 * 60),
            endDate: Scenario.activation.addingTimeInterval(-30 * 60)
        )

        let historical = try replayAfterActivation(history: history(old: old, new: new), doses: [temp])
        expectEqual(historical, try replayWithSingleProfile(old, doses: [temp]))
        // The new schedule would net 4 U/hr against 2 U/hr at ISF 80.
        let reinterpreted = try replayWithSingleProfile(new, doses: [temp])
        #expect(zip(historical, reinterpreted).contains { abs($0.insulinEffect - $1.insulinEffect) > 0.1 })
    }

    @Test("a temp basal crossing activation splits at the activation", arguments: SettingsChange.allCases)
    func tempBasalCrossingActivation(change: SettingsChange) throws {
        let old = try change.old
        let new = try change.new
        func temp(from start: TimeInterval, to end: TimeInterval) -> DoseRecord {
            DoseRecord(
                kind: .tempBasal(unitsPerHour: 3),
                startDate: Scenario.activation.addingTimeInterval(start * 60),
                endDate: Scenario.activation.addingTimeInterval(end * 60)
            )
        }

        // The activation stays a basal boundary even when the basal rate is
        // the same on both sides, so the model splits the temp basal there.
        let timeline = TherapyTimeline(history: history(old: old, new: new), candidate: new, from: Scenario.activation)
        let basal = timeline.basalTimeline(from: Scenario.preChange, to: Scenario.activation.addingTimeInterval(3600))
        #expect(basal.map(\.startDate) == [Scenario.preChange, Scenario.activation])

        let historical = try replayAfterActivation(
            history: history(old: old, new: new),
            doses: [temp(from: -30, to: 30)]
        )
        // Each part is modeled with the settings in force when it was delivered.
        let before = try replayWithSingleProfile(old, doses: [temp(from: -30, to: 0)])
        let after = try replayWithSingleProfile(new, doses: [temp(from: 0, to: 30)])
        #expect(historical.count == before.count)
        #expect(historical.count == after.count)
        for (sample, (a, b)) in zip(historical, zip(before, after)) {
            #expect(sample.date == a.date && sample.date == b.date)
            #expect(abs(sample.insulinEffect - (a.insulinEffect + b.insulinEffect)) < 1e-9)
            #expect(abs(sample.insulinOnBoard - (a.insulinOnBoard + b.insulinOnBoard)) < 1e-9)
        }

        if change == .sensitivity {
            // Unsplit, the post-activation half would keep ISF 40.
            let unsplit = try replayWithSingleProfile(old, doses: [temp(from: -30, to: 30)])
            #expect(zip(historical, unsplit).contains { abs($0.insulinEffect - $1.insulinEffect) > 0.1 })
        }
    }

    @Test("a pre-change meal keeps its recorded carb ratio and ISF after activation")
    func preChangeMeal() throws {
        let old = try Scenario.profile(activeFrom: Scenario.start.addingTimeInterval(-2 * 86_400), isf: 40, carbRatio: 10)
        let new = try Scenario.profile(activeFrom: Scenario.activation, isf: 40, carbRatio: 20)
        let meal = Scenario.meal(30)

        let historical = try replayAfterActivation(history: history(old: old, new: new), carbs: [meal])
        #expect(historical.contains { $0.carbsOnBoard > 0 })
        expectEqual(historical, try replayWithSingleProfile(old, carbs: [meal]))
        let reinterpreted = try replayWithSingleProfile(new, carbs: [meal])
        #expect(zip(historical, reinterpreted).contains { abs($0.deviation - $1.deviation) > 0.1 })
    }

    @Test("an input beginning after activation uses the new settings")
    func postChangeInput() throws {
        let old = try Scenario.old()
        let new = try Scenario.new()
        let preDose = Scenario.bolus(1)
        let postDose = Scenario.bolus(1, at: Scenario.activation.addingTimeInterval(30 * 60))

        let historical = try replayAfterActivation(
            history: history(old: old, new: new),
            doses: [preDose, postDose]
        )
        let pre = try replayWithSingleProfile(old, doses: [preDose])
        let post = try replayWithSingleProfile(new, doses: [postDose])
        #expect(historical.count == pre.count)
        for (sample, (a, b)) in zip(historical, zip(pre, post)) {
            #expect(abs(sample.insulinEffect - (a.insulinEffect + b.insulinEffect)) < 1e-9)
        }
    }

    @Test("a target-only upload does not move the settings activation")
    func targetOnlyUploadKeepsActivation() throws {
        let old = try Scenario.old()
        let new = try Scenario.new()
        var retargeted = new
        retargeted.activeFrom = Scenario.activation.addingTimeInterval(3600)
        retargeted.targetSchedule = try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 90...100)])
        let replay = HistoricalReplay(inputs: TuningInputs(
            profile: retargeted,
            profileHistory: ProfileHistory(timeline: [old, new, retargeted], current: retargeted),
            glucose: Scenario.glucose,
            doses: [],
            carbs: [],
            analysisStart: Scenario.start,
            analysisEnd: Scenario.start.addingTimeInterval(86_400)
        ))

        #expect(replay.settingsActivation(at: Scenario.activation.addingTimeInterval(2 * 3600)) == Scenario.activation)
        #expect(replay.settingsActivation(at: Scenario.activation.addingTimeInterval(-60)) == old.activeFrom)
        #expect(replay.segmentsByDay().joined().map(\.settingsActivation) == [old.activeFrom, Scenario.activation])
    }

    @Test("a return to earlier settings keeps the intervening period for inputs given under it")
    func returnToEarlierSettings() throws {
        let first = try Scenario.old()
        let intervening = try Scenario.profile(activeFrom: Scenario.activation.addingTimeInterval(-2 * 3600), isf: 80)
        var restored = first
        restored.activeFrom = Scenario.activation
        let history = ProfileHistory(timeline: [first, intervening, restored], current: restored)
        let underFirst = Scenario.bolus(1, at: Scenario.activation.addingTimeInterval(-3 * 3600))
        let underIntervening = Scenario.bolus(1, at: Scenario.preChange)

        let historical = try replayAfterActivation(history: history, doses: [underFirst, underIntervening])
        let a = try replayWithSingleProfile(first, doses: [underFirst])
        let b = try replayWithSingleProfile(intervening, doses: [underIntervening])
        #expect(historical.count == a.count)
        for (sample, (a, b)) in zip(historical, zip(a, b)) {
            #expect(abs(sample.insulinEffect - (a.insulinEffect + b.insulinEffect)) < 1e-9)
        }
        // Replaying the restored settings throughout would erase the change.
        let flattened = try replayWithSingleProfile(first, doses: [underFirst, underIntervening])
        #expect(zip(historical, flattened).contains { abs($0.insulinEffect - $1.insulinEffect) > 0.1 })
    }

    @Test("each recorded period expands its schedules in its own time zone")
    func periodInAnotherTimeZone() throws {
        // 00:00 in Tokyo is 15:00 UTC, an hour before the UTC activation.
        let tokyo = TherapyProfile(
            basalSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 1)]),
            sensitivitySchedule: try DailySchedule(entries: [
                .init(secondsSinceMidnight: 0, value: 30),
                .init(secondsSinceMidnight: 12 * 3600, value: 50),
            ]),
            carbRatioSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 10)]),
            targetSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 100...110)]),
            timeZone: TimeZone(identifier: "Asia/Tokyo")!,
            glucoseUnit: .milligramsPerDeciliter,
            activeFrom: Scenario.start.addingTimeInterval(-2 * 86_400),
            insulinType: .novolog
        )
        let new = try Scenario.new()
        let timeline = TherapyTimeline(history: history(old: tokyo, new: new), candidate: new, from: Scenario.activation)
        let sensitivity = timeline.sensitivityTimeline(
            from: Scenario.activation.addingTimeInterval(-2 * 3600),
            to: Scenario.activation.addingTimeInterval(3600)
        )
        #expect(sensitivity.map(\.startDate) == [
            Scenario.activation.addingTimeInterval(-2 * 3600),
            Scenario.preChange,
            Scenario.activation,
        ])
        #expect(sensitivity.map { $0.value.doubleValue(for: .milligramsPerDeciliter) } == [50, 30, 80])

        let dose = Scenario.bolus(1, at: Scenario.activation.addingTimeInterval(-30 * 60))
        let historical = try replayAfterActivation(history: history(old: tokyo, new: new), doses: [dose])
        expectEqual(historical, try replayWithSingleProfile(tokyo, doses: [dose]))
        var tokyoReadAsUTC = tokyo
        tokyoReadAsUTC.timeZone = TimeZone(identifier: "UTC")!
        let misread = try replayWithSingleProfile(tokyoReadAsUTC, doses: [dose])
        #expect(zip(historical, misread).contains { abs($0.insulinEffect - $1.insulinEffect) > 0.1 })
    }

    @Test("a dose without its own insulin type takes the type recorded at its start")
    func perPeriodInsulinType() throws {
        let old = try Scenario.profile(activeFrom: Scenario.start.addingTimeInterval(-2 * 86_400), isf: 40, insulinType: .fiasp)
        let new = try Scenario.profile(activeFrom: Scenario.activation, isf: 40, insulinType: .novolog)
        let dose = Scenario.bolus(1)

        let historical = try replayAfterActivation(history: history(old: old, new: new), doses: [dose])
        expectEqual(historical, try replayWithSingleProfile(old, doses: [dose]))
        let reinterpreted = try replayWithSingleProfile(new, doses: [dose])
        #expect(zip(historical, reinterpreted).contains { abs($0.insulinEffect - $1.insulinEffect) > 0.01 })
    }

    @Test("a timeline composes recorded periods before the activation with the candidate after it")
    func timelineComposition() throws {
        let old = try Scenario.old()
        let new = try Scenario.new()
        let candidate = try Scenario.profile(activeFrom: nil, isf: 60)
        let timeline = TherapyTimeline(
            history: history(old: old, new: new),
            candidate: candidate,
            from: Scenario.activation
        )
        let sensitivity = timeline.sensitivityTimeline(
            from: Scenario.preChange,
            to: Scenario.activation.addingTimeInterval(3600)
        )
        #expect(sensitivity.map(\.startDate) == [Scenario.preChange, Scenario.activation])
        #expect(sensitivity.map { $0.value.doubleValue(for: .milligramsPerDeciliter) } == [40, 60])
        #expect(timeline.profile(at: Scenario.preChange) == old)
        #expect(timeline.profile(at: Scenario.activation) == candidate)

        // Without history the candidate applies throughout, as a single profile.
        let single = TherapyTimeline(history: nil, candidate: candidate, from: Scenario.activation)
        #expect(single.profile(at: Scenario.preChange) == candidate)
        #expect(single.basalTimeline(from: Scenario.start, to: Scenario.activation).count == 1)
    }
}

@Suite("Chained tuning across a profile change")
struct ChainedHistoricalContextTests {
    typealias Scenario = ProfileChangeScenario

    /// A meal after the change, identical in every run. Flat carb-ratio
    /// tuning sums all meal residuals, so the earlier meal's modeled effect
    /// reaches the recommendation through it.
    private func carbs(_ input: PreChangeInput, equivalent: Bool) -> [CarbRecord] {
        let carbs = input.carbs(equivalentUnderNewSettings: equivalent)
        guard input == .meal else { return carbs }
        return carbs + [Scenario.meal(20, at: Scenario.activation.addingTimeInterval(2 * 3600))]
    }

    private func glucose(_ input: PreChangeInput) -> [GlucoseSample] {
        input == .meal ? Scenario.glucoseRisingAfterMeal : Scenario.glucose
    }

    /// The scenario with the change inside the analysis window.
    private func historyInputs(_ input: PreChangeInput) throws -> TuningInputs {
        let new = try Scenario.new()
        return TuningInputs(
            profile: new,
            profileHistory: ProfileHistory(timeline: [try Scenario.old(), new], current: new),
            glucose: glucose(input),
            doses: input.doses(equivalentUnderNewSettings: false),
            carbs: carbs(input, equivalent: false),
            analysisStart: Scenario.start,
            analysisEnd: Scenario.start.addingTimeInterval(86_400)
        )
    }

    /// The post-change period under the new settings alone, with the
    /// pre-change input either converted to its equivalent or reinterpreted.
    private func newSettingsInputs(_ input: PreChangeInput, equivalent: Bool) throws -> TuningInputs {
        TuningInputs(
            profile: try Scenario.new(),
            glucose: glucose(input),
            doses: input.doses(equivalentUnderNewSettings: equivalent),
            carbs: carbs(input, equivalent: equivalent),
            analysisStart: Scenario.activation,
            analysisEnd: Scenario.start.addingTimeInterval(86_400)
        )
    }

    @Test("the recommendation models a pre-change input with its recorded settings", arguments: PreChangeInput.allCases)
    func recommendationUsesRecordedSettings(input: PreChangeInput) throws {
        let result = try ChainedTuner().run(inputs: try historyInputs(input))
        let equivalent = try ChainedTuner().run(inputs: try newSettingsInputs(input, equivalent: true))
        let reinterpreted = try ChainedTuner().run(inputs: try newSettingsInputs(input, equivalent: false))

        #expect(result.settingsChanges == [Scenario.activation])
        #expect(result.output.totalSamples > 0)
        #expect(result.output == equivalent.output)
        #expect(result.daysMissingByHour == equivalent.daysMissingByHour)
        // The single-profile replay this replaces gives a different answer.
        #expect(result.output != reinterpreted.output)
    }

    @Test("the pipeline applies recorded settings to a change before the window", arguments: PreChangeInput.allCases)
    func pipelineChangeInLookback(input: PreChangeInput) throws {
        var inputs = try historyInputs(input)
        inputs.analysisStart = Scenario.activation
        let configuration = TuningConfiguration(days: 1)
        let recommendation = try TuningPipeline().run(inputs: inputs, configuration: configuration)
        let equivalent = try TuningPipeline().run(
            inputs: try newSettingsInputs(input, equivalent: true),
            configuration: configuration
        )
        let reinterpreted = try TuningPipeline().run(
            inputs: try newSettingsInputs(input, equivalent: false),
            configuration: configuration
        )

        func values(_ recommendation: TuningRecommendation) -> [Double] {
            recommendation.basalHours.map(\.recommendedRate)
                + recommendation.sensitivitySchedule.map(\.parameter.recommendedValue)
                + recommendation.carbRatioSchedule.map(\.parameter.recommendedValue)
                + [recommendation.sensitivity.rawTunedValue, recommendation.carbRatio.rawTunedValue]
        }
        #expect(recommendation.settingsChanges.isEmpty)
        #expect(recommendation.totalSamples == equivalent.totalSamples)
        #expect(recommendation.categoryCounts == equivalent.categoryCounts)
        #expect(values(recommendation) == values(equivalent))
        #expect(values(recommendation) != values(reinterpreted))
    }
}

@Suite("Diagnostics across a profile change")
struct DiagnosticsHistoricalContextTests {
    typealias Scenario = ProfileChangeScenario

    @Test("both replays keep recorded settings for a pre-change input", arguments: PreChangeInput.allCases)
    func diagnosticsUseRecordedSettings(input: PreChangeInput) async throws {
        let old = try Scenario.old()
        let new = try Scenario.new()
        let inputs = TuningInputs(
            profile: new,
            profileHistory: ProfileHistory(timeline: [old, new], current: new),
            glucose: Scenario.glucose,
            doses: input.doses(equivalentUnderNewSettings: false),
            carbs: input.carbs(equivalentUnderNewSettings: false),
            analysisStart: Scenario.start,
            analysisEnd: Scenario.start.addingTimeInterval(86_400)
        )
        let recommendation = try TuningPipeline().run(inputs: inputs, configuration: TuningConfiguration(days: 1))
        #expect(abs(recommendation.sensitivity.rawTunedValue - 40) > 1)
        let diagnostics = try await DiagnosticsBuilder().build(inputs: inputs, recommendation: recommendation)

        // Only the pre-change input moves modeled glucose and the basal is
        // unchanged, so the recorded replay equals replaying the old settings
        // throughout.
        var oldOnly = inputs
        oldOnly.profile = old
        oldOnly.profileHistory = nil
        let reference = try await DiagnosticsBuilder().build(inputs: oldOnly, recommendation: recommendation)
        #expect(abs(diagnostics.meanAbsDeviationBefore - reference.meanAbsDeviationBefore) < 1e-9)
        #expect(diagnostics.meanAbsDeviationBefore > 0)
        for (hour, expected) in zip(diagnostics.hourlyDeviation, reference.hourlyDeviation) {
            #expect(abs(hour.before - expected.before) < 1e-9)
        }

        // The recommendation stands in for each settings period, so after the
        // activation it does not reinterpret the earlier input either. Hour 16
        // still holds the 16:00 sample that closes the pre-change segment.
        let postChangeHours = Array(17...23) + Array(0...3)
        for hour in diagnostics.hourlyDeviation where postChangeHours.contains(hour.hour) {
            #expect(abs(hour.after - hour.before) < 1e-9)
        }
        #expect(diagnostics.hourlyDeviation.contains { $0.hour == 17 && abs($0.before) > 0.01 })
        // Before the activation it replaces the old settings.
        #expect(diagnostics.hourlyDeviation.contains { $0.hour == 15 && abs($0.after - $0.before) > 0.01 })
    }
}
