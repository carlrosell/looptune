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
    /// The current profile (what is in Loop now) — the recommendation baseline.
    public var profile: TherapyProfile
    /// Full profile history, when available: lets the tuner replay each day
    /// against the settings that were actually active then.
    public var profileHistory: ProfileHistory?
    public var glucose: [GlucoseSample]
    public var doses: [DoseRecord]
    public var carbs: [CarbRecord]
    public var analysisStart: Date
    public var analysisEnd: Date

    public init(
        profile: TherapyProfile,
        profileHistory: ProfileHistory? = nil,
        glucose: [GlucoseSample],
        doses: [DoseRecord],
        carbs: [CarbRecord],
        analysisStart: Date,
        analysisEnd: Date
    ) {
        self.profile = profile
        self.profileHistory = profileHistory
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
                daysTuned: result.daysTuned,
                settingsChanges: result.settingsChanges
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

    /// Fetch from a Nightscout site and run tuning. When a `cache` is supplied,
    /// finished days load from disk and only fresh/incomplete days hit the
    /// network.
    public func run(
        client: NightscoutClient,
        configuration: TuningConfiguration,
        endingAt end: Date,
        cache: DayCache? = nil
    ) async throws -> TuningRecommendation {
        let inputs = try await fetchInputs(client: client, configuration: configuration, endingAt: end, cache: cache)
        return try run(inputs: inputs, configuration: configuration)
    }

    /// Fetch and run tuning, returning the recommendation together with the
    /// full diagnostics (ingested-data summaries and before/after deviation).
    public func runWithDiagnostics(
        client: NightscoutClient,
        configuration: TuningConfiguration,
        endingAt end: Date,
        cache: DayCache? = nil
    ) async throws -> (recommendation: TuningRecommendation, diagnostics: RunDiagnostics, host: String) {
        let inputs = try await fetchInputs(client: client, configuration: configuration, endingAt: end, cache: cache)
        let recommendation = try run(inputs: inputs, configuration: configuration)
        let diagnostics = DiagnosticsBuilder().build(inputs: inputs, recommendation: recommendation)
        return (recommendation, diagnostics, client.baseURL.host ?? "unknown")
    }

    /// Fetch and assemble inputs from Nightscout, day-bucket by day-bucket.
    ///
    /// The window is tiled with UTC day buckets (plus one lead-in day so doses
    /// within the insulin tail before the window are present, and a trailing
    /// margin covering the carb-ratio timeline). With a `cache`, each finished
    /// bucket is served from disk when available and stored after fetching;
    /// the current (unfinished) day is always fetched live and never stored.
    public func fetchInputs(
        client: NightscoutClient,
        configuration: TuningConfiguration,
        endingAt end: Date,
        cache: DayCache? = nil
    ) async throws -> TuningInputs {
        let analysisStart = end.addingTimeInterval(-Double(configuration.days) * 86_400)

        // Profile history: always fetched fresh. Loop uploads a new document on
        // every settings change, so the history lets each day replay against
        // the settings that were actually active then.
        let profileDocs = try await client.fetchProfiles(count: 100)
        guard !profileDocs.isEmpty else { throw PipelineError.noProfile }
        let history = try ProfileIngest.makeHistory(from: profileDocs)
        var profile = history.current
        if profile.insulinType == nil { profile.insulinType = configuration.insulinType }

        cache?.pruneExpired()

        // One lead-in day covers the 18h treatment lookback and the 30-min
        // glucose delta lead; 6h trailing margin covers carb-ratio coverage.
        let fetchStart = analysisStart.addingTimeInterval(-DayCache.dayLength)
        let fetchEnd = end.addingTimeInterval(6 * 3600)
        let buckets = DayCache.utcDayBuckets(covering: fetchStart, to: fetchEnd)
        let host = client.baseURL.host ?? "unknown"

        var entries: [NSEntry] = []
        var treatments: [NSTreatment] = []
        for bucket in buckets {
            if let cache, let cached = cache.load(host: host, dayKey: bucket.key) {
                entries += cached.entries
                treatments += cached.treatments
                continue
            }
            let dayEntries = try await client.fetchEntries(from: bucket.interval.start, to: bucket.interval.end, count: 1500)
            let dayTreatments = try await client.fetchTreatments(from: bucket.interval.start, to: bucket.interval.end, count: 1500)
            entries += dayEntries
            treatments += dayTreatments
            if let cache, cache.shouldStore(dayEnd: bucket.interval.end) {
                cache.store(
                    CachedDay(day: bucket.key, fetchedAt: Date(), entries: dayEntries, treatments: dayTreatments),
                    host: host
                )
            }
        }

        let glucose = GlucoseIngest.ingest(entries)
        let ingested = TreatmentIngest.ingest(Self.dedupeAcrossBuckets(treatments))

        return TuningInputs(
            profile: profile,
            profileHistory: history,
            glucose: glucose,
            doses: ingested.doses,
            carbs: ingested.carbs,
            analysisStart: analysisStart,
            analysisEnd: end
        )
    }

    /// Nightscout range queries are inclusive at both ends, so a document with
    /// a timestamp exactly on a bucket boundary appears in two buckets. Drop
    /// exact duplicates before ingestion (boluses would otherwise double).
    static func dedupeAcrossBuckets(_ treatments: [NSTreatment]) -> [NSTreatment] {
        var seen = Set<String>()
        var result: [NSTreatment] = []
        for treatment in treatments {
            let time: String = String(treatment.createdAt.timeIntervalSince1970)
            let type: String = treatment.eventType ?? ""
            let insulin: String = treatment.insulin.map { String($0) } ?? ""
            let carbs: String = treatment.carbs.map { String($0) } ?? ""
            let rate: String = treatment.rate.map { String($0) } ?? ""
            let duration: String = treatment.duration.map { String($0) } ?? ""
            let key = "\(time)|\(type)|\(insulin)|\(carbs)|\(rate)|\(duration)"
            if seen.insert(key).inserted {
                result.append(treatment)
            }
        }
        return result
    }
}
