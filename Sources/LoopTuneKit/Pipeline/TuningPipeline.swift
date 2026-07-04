import Foundation

/// User-facing options for a tuning run.
public struct TuningConfiguration: Sendable {
    /// Days of history to analyze (clamped to 1…30).
    public var days: Int
    /// Insulin type Loop is configured with (NS profiles don't carry it).
    public var insulinType: InsulinType
    /// Treat unannounced-meal data as basal (Loop has no UAM).
    public var categorizeUAMAsBasal: Bool

    public init(days: Int = 7, insulinType: InsulinType = .novolog, categorizeUAMAsBasal: Bool = true) {
        self.days = min(30, max(1, days))
        self.insulinType = insulinType
        self.categorizeUAMAsBasal = categorizeUAMAsBasal
    }
}

/// All the raw data one run needs — separable from fetching so the pipeline can
/// run offline against captured JSON.
public struct TuningInputs: Sendable {
    public var profile: TherapyProfile
    public var glucose: [GlucoseSample]
    public var doses: [DoseRecord]
    public var carbs: [CarbRecord]
    public var analysisStart: Date
    public var analysisEnd: Date

    public init(profile: TherapyProfile, glucose: [GlucoseSample], doses: [DoseRecord], carbs: [CarbRecord], analysisStart: Date, analysisEnd: Date) {
        self.profile = profile
        self.glucose = glucose
        self.doses = doses
        self.carbs = carbs
        self.analysisStart = analysisStart
        self.analysisEnd = analysisEnd
    }
}

/// End-to-end tuning: replay → categorize → tune → recommend.
public struct TuningPipeline: Sendable {
    public init() {}

    public enum PipelineError: Error, Equatable {
        case noProfile
        case noGlucose
    }

    /// Run tuning against already-assembled inputs (offline path).
    ///
    /// Windows longer than one day are tuned with day-by-day chaining: each
    /// day's tuned profile seeds the next day's replay while the pump profile
    /// stays fixed as the safety-cap baseline (oref0's model).
    public func run(inputs: TuningInputs, configuration: TuningConfiguration) throws -> TuningRecommendation {
        guard inputs.glucose.count >= 2 else { throw PipelineError.noGlucose }

        var profile = inputs.profile
        if profile.insulinType == nil {
            profile.insulinType = configuration.insulinType
        }
        var chainInputs = inputs
        chainInputs.profile = profile

        let options = CategorizerOptions(categorizeUAMAsBasal: configuration.categorizeUAMAsBasal)
        let days = max(1, Int((inputs.analysisEnd.timeIntervalSince(inputs.analysisStart) / 86_400).rounded()))

        if days > 1 {
            let result = try ChainedTuner(options: options).run(inputs: chainInputs)
            return TuningRecommendation(
                from: result.output,
                daysAnalyzed: days,
                profileGlucoseUnit: profile.glucoseUnit,
                daysMissingByHour: result.daysMissingByHour,
                daysTuned: result.daysTuned
            )
        }

        let deviations = try ReplayEngine().computeDeviations(
            glucose: inputs.glucose,
            doses: inputs.doses,
            carbs: inputs.carbs,
            profile: profile,
            analysisStart: inputs.analysisStart,
            analysisEnd: inputs.analysisEnd
        )

        let tuner = LoopTuner(options: options)
        let output = tuner.tune(
            deviations: deviations,
            carbs: inputs.carbs,
            currentProfile: profile,
            pumpProfile: profile,
            analysisStart: inputs.analysisStart,
            analysisEnd: inputs.analysisEnd
        )

        return TuningRecommendation(from: output, daysAnalyzed: days, profileGlucoseUnit: profile.glucoseUnit)
    }

    /// Fetch from a Nightscout site and run tuning.
    public func run(client: NightscoutClient, configuration: TuningConfiguration, endingAt end: Date) async throws -> TuningRecommendation {
        let inputs = try await fetchInputs(client: client, configuration: configuration, endingAt: end)
        return try run(inputs: inputs, configuration: configuration)
    }

    /// Fetch and assemble inputs from Nightscout.
    public func fetchInputs(client: NightscoutClient, configuration: TuningConfiguration, endingAt end: Date) async throws -> TuningInputs {
        let analysisStart = end.addingTimeInterval(-Double(configuration.days) * 86_400)

        // Profile: use the current (most recent) document. Profile-history
        // alignment per day is a future refinement.
        let profiles = try await client.fetchProfiles(count: 1)
        guard let profileDoc = profiles.first else { throw PipelineError.noProfile }
        var profile = try ProfileIngest.makeProfile(from: profileDoc)
        if profile.insulinType == nil { profile.insulinType = configuration.insulinType }

        // Entries: analysis window plus a short lead-in for deltas.
        let entryStart = analysisStart.addingTimeInterval(-30 * 60)
        let entries = try await client.fetchEntries(from: entryStart, to: end, count: 400 * configuration.days)
        let glucose = GlucoseIngest.ingest(entries)

        // Treatments: pad for DIA lookback + timezone skew (oref0-style).
        let treatmentStart = analysisStart.addingTimeInterval(-18 * 3600)
        let treatmentEnd = end.addingTimeInterval(6 * 3600)
        let treatments = try await client.fetchTreatments(from: treatmentStart, to: treatmentEnd, count: 1000 * configuration.days)
        let ingested = TreatmentIngest.ingest(treatments)

        return TuningInputs(
            profile: profile,
            glucose: glucose,
            doses: ingested.doses,
            carbs: ingested.carbs,
            analysisStart: analysisStart,
            analysisEnd: end
        )
    }
}
