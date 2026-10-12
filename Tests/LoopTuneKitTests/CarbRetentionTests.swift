import Testing
import Foundation
@testable import LoopTuneKit

/// The CORE-07 scenario: flat five-minute CGM, basal 1, ISF 40, CR 10, and a
/// one-hour segment that starts long after a slow meal.
struct CarbRetentionScenario {
    // 2023-11-13 04:00 UTC.
    static let segmentStart = Date(timeIntervalSince1970: 1_699_833_600 + 4 * 3600)
    static let segmentEnd = segmentStart.addingTimeInterval(3600)
    static let dayEnd = segmentStart.addingTimeInterval(86_400)

    static func profile() throws -> TherapyProfile {
        try ProfileChangeScenario.profile(activeFrom: nil, isf: 40)
    }

    /// Flat CGM from two days before the segment through `end`.
    static func glucose(through end: Date = segmentEnd) -> [GlucoseSample] {
        let count = Int(end.timeIntervalSince(segmentStart) / 300)
        return (-576...count).map {
            GlucoseSample(date: segmentStart.addingTimeInterval(Double($0) * 300), milligramsPerDeciliter: 120)
        }
    }

    /// Half-hour temp basals over the same span. Their net insulin against the
    /// 1 U/hr schedule, with flat CGM, gives counteraction effects that the
    /// model attributes to active meals. At 1.5 U/hr that observed absorption
    /// outpaces a slow meal's modeled minimum; at 1.1 U/hr it falls below it,
    /// so the model spreads the remainder over the meal's whole span.
    static func temps(unitsPerHour: Double, through end: Date = segmentEnd) -> [DoseRecord] {
        let count = Int(end.timeIntervalSince(segmentStart) / 1800)
        return (-96..<count).map {
            let start = segmentStart.addingTimeInterval(Double($0) * 1800)
            return DoseRecord(
                kind: .tempBasal(unitsPerHour: unitsPerHour),
                startDate: start,
                endDate: start.addingTimeInterval(1800)
            )
        }
    }

    /// Dose histories for the boundary cases: none, so absorption follows the
    /// entered model, and slow counteraction, so it follows the minimum rate.
    static let boundaryDoses: [[DoseRecord]] = [[], temps(unitsPerHour: 1.1)]

    static func meal(hoursBefore hours: Double, absorptionHours: Double, grams: Double = 60) -> CarbRecord {
        CarbRecord(
            date: segmentStart.addingTimeInterval(-hours * 3600),
            grams: grams,
            absorptionTime: absorptionHours * 3600
        )
    }

    /// Replay the segment from every input, or from those `trimmedInputs`
    /// retains for it.
    static func replay(
        carbs: [CarbRecord],
        doses: [DoseRecord] = [],
        trimmed: Bool,
        end: Date = segmentEnd
    ) throws -> [DeviationSample] {
        let glucose = glucose(through: end)
        var inputs = (glucose: glucose, doses: doses, carbs: carbs)
        if trimmed {
            inputs = ReplayEngine.trimmedInputs(
                glucose: glucose,
                doses: doses,
                carbs: carbs,
                analysisStart: segmentStart,
                analysisEnd: end
            )
        }
        return try ReplayEngine().computeDeviations(
            glucose: inputs.glucose,
            doses: inputs.doses,
            carbs: inputs.carbs,
            profile: profile(),
            analysisStart: segmentStart,
            analysisEnd: end
        )
    }

    /// A one-day analysis window starting at the segment.
    static func dayInputs(carbs: [CarbRecord]) throws -> TuningInputs {
        TuningInputs(
            profile: try profile(),
            glucose: glucose(through: dayEnd),
            doses: [],
            carbs: carbs,
            analysisStart: segmentStart,
            analysisEnd: dayEnd
        )
    }
}

@Suite("Carbohydrate retention")
struct CarbRetentionTests {
    typealias Scenario = CarbRetentionScenario

    static let auditMeal = Scenario.meal(hoursBefore: 10.5, absorptionHours: 8)

    @Test("an 8-hour meal 10.5 hours before the segment survives trimming")
    func auditReproduction() throws {
        let full = try Scenario.replay(carbs: [Self.auditMeal], trimmed: false)
        let trimmed = try Scenario.replay(carbs: [Self.auditMeal], trimmed: true)

        let first = try #require(full.first)
        #expect(abs(first.carbsOnBoard - 1.547497) < 1e-6)
        #expect(abs(first.deviation - -0.668724) < 1e-6)
        expectEqual(trimmed, full)
    }

    @Test("retention derives from the longest supported modeled absorption")
    func derivedBounds() {
        // 1.5 × 8h + 10 min.
        #expect(ReplayEngine.carbAbsorptionSpan(absorptionTime: 8 * 3600) == 12 * 3600 + 600)
        #expect(CarbRecord.maximumAbsorptionTime == 10 * 3600)
        // 1.5 × 10h + 10 min span, plus 35 min of margin.
        #expect(ReplayEngine.carbLookback == 15 * 3600 + 45 * 60)
        #expect(ReplayEngine.glucoseLookback == ReplayEngine.carbLookback)
        #expect(ReplayEngine.doseLookback == 23 * 3600 + 45 * 60)
        #expect(ReplayEngine.doseLookback - ReplayEngine.glucoseLookback >= ReplayEngine.insulinActivityDuration)
        #expect(ReplayEngine.inputLookback == ReplayEngine.doseLookback)
    }

    @Test("a meal at the carb lookback is retained and one just before it is not")
    func retentionBoundary() throws {
        let atBound = CarbRecord(date: Scenario.segmentStart.addingTimeInterval(-ReplayEngine.carbLookback), grams: 60)
        let beyond = CarbRecord(date: atBound.date.addingTimeInterval(-1), grams: 60)
        let retained = ReplayEngine.trimmedInputs(
            glucose: Scenario.glucose(),
            doses: [],
            carbs: [beyond, atBound],
            analysisStart: Scenario.segmentStart,
            analysisEnd: Scenario.segmentEnd
        )
        #expect(retained.carbs == [atBound])
        #expect(retained.glucose.first?.date == Scenario.segmentStart.addingTimeInterval(-ReplayEngine.glucoseLookback))
    }

    @Test("a longest-absorption meal ending just inside the segment is replayed in full")
    func justInsideBound() throws {
        let span = ReplayEngine.carbAbsorptionSpan(absorptionTime: CarbRecord.maximumAbsorptionTime)
        let meal = CarbRecord(
            date: Scenario.segmentStart.addingTimeInterval(-span + 15 * 60),
            grams: 60,
            absorptionTime: CarbRecord.maximumAbsorptionTime
        )
        for doses in Scenario.boundaryDoses {
            let full = try Scenario.replay(carbs: [meal], doses: doses, trimmed: false)
            let withoutMeal = try Scenario.replay(carbs: [], doses: doses, trimmed: false)

            #expect(try #require(full.first).carbsOnBoard > 0)
            #expect(zip(full, withoutMeal).contains { abs($0.deviation - $1.deviation) > 1e-3 })
            expectEqual(try Scenario.replay(carbs: [meal], doses: doses, trimmed: true), full)
        }
    }

    @Test("a longest-absorption meal starting before the carb lookback cannot affect the segment")
    func justOutsideBound() throws {
        let meal = CarbRecord(
            date: Scenario.segmentStart.addingTimeInterval(-ReplayEngine.carbLookback - 1),
            grams: 60,
            absorptionTime: CarbRecord.maximumAbsorptionTime
        )
        for doses in Scenario.boundaryDoses {
            let full = try Scenario.replay(carbs: [meal], doses: doses, trimmed: false)

            expectEqual(full, try Scenario.replay(carbs: [], doses: doses, trimmed: false))
            expectEqual(try Scenario.replay(carbs: [meal], doses: doses, trimmed: true), full)
        }
    }

    @Test(
        "overrun and effect delay keep a meal active past its entered absorption time",
        arguments: [
            // 1.5 × 8h ends 90 min after the segment starts.
            (hoursBefore: 10.5, absorptionHours: 8.0),
            // 1.5 × 10h ends at the segment start; only the delay remains.
            (hoursBefore: 15.0, absorptionHours: 10.0),
        ]
    )
    func overrunAndDelay(hoursBefore: Double, absorptionHours: Double) throws {
        let meal = Scenario.meal(hoursBefore: hoursBefore, absorptionHours: absorptionHours)
        for doses in Scenario.boundaryDoses {
            let full = try Scenario.replay(carbs: [meal], doses: doses, trimmed: false)
            #expect(try #require(full.first).carbsOnBoard > 0)
            expectEqual(try Scenario.replay(carbs: [meal], doses: doses, trimmed: true), full)
        }
    }

    @Test("an earlier meal that overlapped an active one is retained")
    func overlappingMeals() throws {
        // `earlier` absorbs until 1h50m before the segment; `active` reaches
        // into it. Both share observed absorption while they overlap.
        let earlier = Scenario.meal(hoursBefore: 14, absorptionHours: 8)
        let active = Scenario.meal(hoursBefore: 9, absorptionHours: 8, grams: 40)
        let doses = Scenario.temps(unitsPerHour: 1.5)
        let full = try Scenario.replay(carbs: [earlier, active], doses: doses, trimmed: false)
        let activeOnly = try Scenario.replay(carbs: [active], doses: doses, trimmed: false)

        // Dropping the earlier meal would change the active meal's replay.
        #expect(zip(full, activeOnly).contains { abs($0.carbsOnBoard - $1.carbsOnBoard) > 1e-3 })
        expectEqual(try Scenario.replay(carbs: [earlier, active], doses: doses, trimmed: true), full)
    }

    @Test("chained tuning replays a pre-window meal that is still active")
    func chainedTuning() throws {
        let inputs = try Scenario.dayInputs(carbs: [Self.auditMeal])
        let chained = try ChainedTuner().run(inputs: inputs).output

        func directTuning(carbs: [CarbRecord]) throws -> TuningOutput {
            let deviations = try ReplayEngine().computeDeviations(
                glucose: inputs.glucose,
                doses: [],
                carbs: carbs,
                profile: inputs.profile,
                analysisStart: Scenario.segmentStart,
                analysisEnd: Scenario.dayEnd
            )
            return try LoopTuner().tune(
                deviations: deviations,
                carbs: [],
                attributionCarbs: carbs,
                currentProfile: inputs.profile,
                pumpProfile: inputs.profile,
                analysisStart: Scenario.segmentStart,
                analysisEnd: Scenario.dayEnd
            )
        }
        let full = try directTuning(carbs: [Self.auditMeal])
        let dropped = try directTuning(carbs: [])

        // Without the meal, the first hours replay as basal evidence.
        #expect(full.categoryCounts != dropped.categoryCounts)
        #expect(chained.categoryCounts == full.categoryCounts)
        #expect(chained.basalSampleCountByHour == full.basalSampleCountByHour)
        #expect(chained.tunedBasalHourly == full.tunedBasalHourly)
        #expect(chained.sensitivitySchedule.map(\.tunedValue) == full.sensitivitySchedule.map(\.tunedValue))
        #expect(chained.carbRatioSchedule.map(\.tunedValue) == full.carbRatioSchedule.map(\.tunedValue))
    }

    @Test("diagnostics replay a pre-window meal that is still active")
    func diagnostics() async throws {
        let inputs = try Scenario.dayInputs(carbs: [Self.auditMeal])
        let recommendation = try TuningPipeline().run(inputs: inputs, configuration: TuningConfiguration(days: 1))
        let diagnostics = try await DiagnosticsBuilder().build(inputs: inputs, recommendation: recommendation)

        let full = try Scenario.replay(carbs: [Self.auditMeal], trimmed: false, end: Scenario.dayEnd)
        let meanAbsolute = full.reduce(0) { $0 + abs($1.deviation) } / Double(full.count)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = inputs.profile.timeZone
        let fourAM = full.filter { calendar.component(.hour, from: $0.date) == 4 }
        let fourAMMean = fourAM.reduce(0) { $0 + $1.deviation } / Double(fourAM.count)

        // The meal still absorbing after 04:00 drives this hour's deviations.
        #expect(fourAMMean < -0.1)
        #expect(abs(diagnostics.meanAbsDeviationBefore - meanAbsolute) < 1e-9)
        let hour = try #require(diagnostics.hourlyDeviation.first { $0.hour == 4 })
        #expect(abs(hour.before - fourAMMean) < 1e-9)
    }

    @Test("absorption times above the supported bound fail explicitly")
    func unsupportedAbsorptionTime() async throws {
        let supported = Scenario.meal(hoursBefore: 10.5, absorptionHours: 10)
        let unsupported = CarbRecord(
            date: supported.date,
            grams: 60,
            absorptionTime: CarbRecord.maximumAbsorptionTime + 60
        )
        let configuration = TuningConfiguration(days: 1)

        let recommendation = try TuningPipeline().run(
            inputs: Scenario.dayInputs(carbs: [supported]),
            configuration: configuration
        )
        // The earliest unsupported entry is reported, in the profile's zone.
        let later = CarbRecord(date: unsupported.date.addingTimeInterval(3600), grams: 30, absorptionTime: 12 * 3600)
        #expect(throws: TuningPipeline.PipelineError.unsupportedCarbAbsorption(
            date: unsupported.date,
            grams: 60,
            absorptionTime: CarbRecord.maximumAbsorptionTime + 60,
            timeZone: TimeZone(identifier: "UTC")!
        )) {
            try TuningPipeline().run(inputs: Scenario.dayInputs(carbs: [later, unsupported]), configuration: configuration)
        }
        let inputs = try Scenario.dayInputs(carbs: [unsupported])
        #expect(throws: ReplayEngine.ReplayError.unsupportedAbsorptionTime(unsupported.date)) {
            try ChainedTuner().run(inputs: inputs)
        }
        await #expect(throws: ReplayEngine.ReplayError.unsupportedAbsorptionTime(unsupported.date)) {
            try await DiagnosticsBuilder().build(inputs: inputs, recommendation: recommendation)
        }
    }

    @Test("the unsupported absorption message names the entry, the limit, and the fix")
    func unsupportedAbsorptionMessage() {
        let meal = Scenario.meal(hoursBefore: 10.5, absorptionHours: 12, grams: 45.5)
        let error = TuningPipeline.PipelineError.unsupportedCarbAbsorption(
            date: meal.date,
            grams: meal.grams,
            absorptionTime: meal.absorptionTime,
            timeZone: TimeZone(identifier: "America/New_York")!
        )
        #expect(error.errorDescription == """
            The 45.5 g carb entry at 2023-11-12 12:30 (America/New_York) has an absorption time \
            of 12 h; LoopTune supports at most 10 h. Edit that entry's absorption time to 10 h or \
            less in Loop or Nightscout, or choose an analysis window that starts at least two days \
            after it. No recommendation was made.
            """)

        let justOver = TuningPipeline.PipelineError.unsupportedCarbAbsorption(
            date: meal.date,
            grams: 60,
            absorptionTime: CarbRecord.maximumAbsorptionTime + 20,
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        )
        #expect(justOver.errorDescription?.hasPrefix(
            "The 60 g carb entry at 2023-11-13 02:30 (Asia/Tokyo) has an absorption time of 10 h 1 min;"
        ) == true)
        #expect(TuningPipeline.PipelineError.noGlucose.errorDescription == nil)
    }
}

func expectEqual(
    _ lhs: [DeviationSample],
    _ rhs: [DeviationSample],
    tolerance: Double = 1e-9,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(!lhs.isEmpty, sourceLocation: sourceLocation)
    #expect(lhs.count == rhs.count, sourceLocation: sourceLocation)
    for (a, b) in zip(lhs, rhs) {
        #expect(a.date == b.date, sourceLocation: sourceLocation)
        #expect(abs(a.insulinEffect - b.insulinEffect) < tolerance, sourceLocation: sourceLocation)
        #expect(abs(a.deviation - b.deviation) < tolerance, sourceLocation: sourceLocation)
        #expect(abs(a.carbsOnBoard - b.carbsOnBoard) < tolerance, sourceLocation: sourceLocation)
    }
}
