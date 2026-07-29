import Foundation

/// User-facing options for a tuning run.
public struct TuningConfiguration: Sendable {
    /// Days of history to analyze (clamped to 1…30).
    public var days: Int {
        didSet { days = min(30, max(1, days)) }
    }
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
    /// Insulin-needs overrides are excluded from attribution unless they only
    /// change the correction target.
    public var overrides: [OverridePeriod]
    public var analysisStart: Date
    public var analysisEnd: Date

    public init(
        profile: TherapyProfile,
        profileHistory: ProfileHistory? = nil,
        glucose: [GlucoseSample],
        doses: [DoseRecord],
        carbs: [CarbRecord],
        overrides: [OverridePeriod] = [],
        analysisStart: Date,
        analysisEnd: Date
    ) {
        self.profile = profile
        self.profileHistory = profileHistory
        self.glucose = glucose
        self.doses = doses
        self.carbs = carbs
        self.overrides = overrides
        self.analysisStart = analysisStart
        self.analysisEnd = analysisEnd
    }

    /// Whether an instant is inside an override that changes insulin needs.
    public func isExcludedFromTuning(_ date: Date) -> Bool {
        overrides.contains { $0.affectsInsulinNeeds && $0.contains(date) }
    }

    func eligibleDeviations(_ samples: [DeviationSample]) -> [DeviationSample] {
        samples.filter { !isExcludedFromTuning($0.date) }
    }

    func eligibleCarbs(from start: Date, to end: Date) -> [CarbRecord] {
        carbs.filter {
            $0.date >= start && $0.date < end && !isExcludedFromTuning($0.date)
        }
    }
}

/// End-to-end tuning: replay → categorize → tune → recommend.
public struct TuningPipeline: Sendable {
    public init() {}

    public enum PipelineError: Error, Equatable {
        case noProfile
        case noGlucose
        case invalidAnalysisWindow
        case insufficientUsableData(minimum: Int, actual: Int)
        case invalidInput(String)
    }

    /// One hour of five-minute intervals: the smallest evidence set allowed to
    /// produce a user-facing recommendation.
    public static let minimumUsableSamples = 12

    /// Run tuning against already-assembled inputs (offline path).
    ///
    /// Windows longer than one day are tuned with day-by-day chaining: each
    /// day's tuned profile seeds the next day's replay while the pump profile
    /// stays fixed as the safety-cap baseline (oref0's model).
    public func run(inputs: TuningInputs, configuration: TuningConfiguration) throws -> TuningRecommendation {
        try Self.validate(inputs)
        guard inputs.analysisStart < inputs.analysisEnd else {
            throw PipelineError.invalidAnalysisWindow
        }
        let glucoseInWindow = inputs.glucose.filter {
            $0.date >= inputs.analysisStart && $0.date <= inputs.analysisEnd
        }
        guard glucoseInWindow.count >= 2 else { throw PipelineError.noGlucose }

        let chainInputs = Self.applyingConfiguration(configuration, to: inputs)
        let profile = chainInputs.profile

        let options = CategorizerOptions(categorizeUAMAsBasal: configuration.categorizeUAMAsBasal)
        let days = max(1, Int(ceil(inputs.analysisEnd.timeIntervalSince(inputs.analysisStart) / 86_400)))
        let fullWindow = DateInterval(start: inputs.analysisStart, end: inputs.analysisEnd)
        let hasTherapyChangeInsideWindow = ChainedTuner.profileSegments(
            for: fullWindow,
            history: chainInputs.profileHistory
        ).count > 1

        if days > 1 || hasTherapyChangeInsideWindow {
            let result = try ChainedTuner(options: options).run(inputs: chainInputs)
            guard result.output.totalSamples >= Self.minimumUsableSamples else {
                throw PipelineError.insufficientUsableData(
                    minimum: Self.minimumUsableSamples,
                    actual: result.output.totalSamples
                )
            }
            return TuningRecommendation(
                from: result.output,
                daysAnalyzed: days,
                profileGlucoseUnit: profile.glucoseUnit,
                daysMissingByHour: result.daysMissingByHour,
                daysTuned: result.daysTuned,
                settingsChanges: result.settingsChanges,
                excludedOverrideSamples: result.excludedOverrideSamples
            )
        }

        let allDeviations = try ReplayEngine().computeDeviations(
            glucose: inputs.glucose,
            doses: inputs.doses,
            carbs: inputs.carbs,
            profile: profile,
            analysisStart: inputs.analysisStart,
            analysisEnd: inputs.analysisEnd
        )
        let deviations = inputs.eligibleDeviations(allDeviations)
        guard deviations.count >= Self.minimumUsableSamples else {
            throw PipelineError.insufficientUsableData(
                minimum: Self.minimumUsableSamples,
                actual: deviations.count
            )
        }

        let tuner = LoopTuner(options: options)
        let output = tuner.tune(
            deviations: deviations,
            carbs: inputs.eligibleCarbs(from: inputs.analysisStart, to: inputs.analysisEnd),
            currentProfile: profile,
            pumpProfile: profile,
            analysisStart: inputs.analysisStart,
            analysisEnd: inputs.analysisEnd
        )

        return TuningRecommendation(
            from: output,
            daysAnalyzed: days,
            profileGlucoseUnit: profile.glucoseUnit,
            excludedOverrideSamples: allDeviations.count - deviations.count
        )
    }

    /// Validate the public offline input boundary before any values reach
    /// LoopAlgorithm, whose lower-level APIs reasonably assume finite,
    /// physiological data and may precondition-fail on corrupt values.
    private static func validate(_ inputs: TuningInputs) throws {
        func finite(_ date: Date) -> Bool {
            date.timeIntervalSinceReferenceDate.isFinite
        }
        func validate(profile: TherapyProfile) throws {
            guard profile.basalSchedule.entries.allSatisfy({
                $0.value.isFinite && $0.value >= 0
            }) else { throw PipelineError.invalidInput("basal schedule") }
            guard profile.sensitivitySchedule.entries.allSatisfy({
                $0.value.isFinite && $0.value > 0
            }) else { throw PipelineError.invalidInput("sensitivity schedule") }
            guard profile.carbRatioSchedule.entries.allSatisfy({
                $0.value.isFinite && $0.value > 0
            }) else { throw PipelineError.invalidInput("carb-ratio schedule") }
            guard profile.targetSchedule.entries.allSatisfy({
                $0.value.lowerBound.isFinite
                    && $0.value.upperBound.isFinite
                    && $0.value.lowerBound > 0
            }) else { throw PipelineError.invalidInput("target schedule") }
            if let activeFrom = profile.activeFrom, !finite(activeFrom) {
                throw PipelineError.invalidInput("profile activation date")
            }
            let positiveLimits = [
                profile.suspendThresholdMilligramsPerDeciliter,
                profile.maximumBasalRatePerHour,
            ].compactMap { $0 }
            let validMaximumBolus = profile.maximumBolus.map {
                $0.isFinite && $0 >= 0
            } ?? true
            guard positiveLimits.allSatisfy({ $0.isFinite && $0 > 0 }),
                  validMaximumBolus else {
                throw PipelineError.invalidInput("profile limits")
            }
        }

        guard finite(inputs.analysisStart), finite(inputs.analysisEnd) else {
            throw PipelineError.invalidInput("analysis dates")
        }
        try validate(profile: inputs.profile)
        if let history = inputs.profileHistory {
            try validate(profile: history.current)
            for profile in history.timeline {
                try validate(profile: profile)
            }
        }
        guard inputs.glucose.allSatisfy({
            finite($0.date)
                && $0.milligramsPerDeciliter.isFinite
                && $0.milligramsPerDeciliter >= GlucoseSample.minimumValidValue
        }) else { throw PipelineError.invalidInput("glucose") }
        guard inputs.doses.allSatisfy({ dose in
            guard finite(dose.startDate), finite(dose.endDate), dose.endDate >= dose.startDate else {
                return false
            }
            switch dose.kind {
            case .bolus(let units):
                return units.isFinite && units >= 0
            case .tempBasal(let unitsPerHour):
                return unitsPerHour.isFinite && unitsPerHour >= 0 && dose.endDate > dose.startDate
            case .suspend:
                return dose.endDate > dose.startDate
            }
        }) else { throw PipelineError.invalidInput("doses") }
        guard inputs.carbs.allSatisfy({
            finite($0.date)
                && $0.grams.isFinite && $0.grams > 0
                && $0.absorptionTime.isFinite && $0.absorptionTime > 0
        }) else { throw PipelineError.invalidInput("carbs") }
        guard inputs.overrides.allSatisfy({ period in
            let validEnd = period.endDate.map {
                finite($0) && $0 > period.startDate
            } ?? true
            let validScale = period.insulinNeedsScaleFactor.map {
                $0.isFinite && $0 > 0
            } ?? true
            let validRange = period.correctionRangeMilligramsPerDeciliter.map {
                $0.lowerBound.isFinite
                    && $0.upperBound.isFinite
                    && $0.lowerBound > 0
            } ?? true
            return finite(period.startDate) && validEnd && validScale && validRange
        }) else { throw PipelineError.invalidInput("overrides") }
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
        let configuredInputs = Self.applyingConfiguration(configuration, to: inputs)
        let recommendation = try run(inputs: configuredInputs, configuration: configuration)
        let diagnostics = await DiagnosticsBuilder().build(
            inputs: configuredInputs,
            recommendation: recommendation
        )
        return (recommendation, diagnostics, client.baseURL.host ?? "unknown")
    }

    private static func applyingConfiguration(
        _ configuration: TuningConfiguration,
        to inputs: TuningInputs
    ) -> TuningInputs {
        var configured = inputs
        if configured.profile.insulinType == nil {
            configured.profile.insulinType = configuration.insulinType
        }
        configured.profileHistory = configured.profileHistory?
            .applyingDefaultInsulinType(configuration.insulinType)
        return configured
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
            overrides: ingested.overrides,
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
            let key: String
            if let syncIdentifier = treatment.syncIdentifier, !syncIdentifier.isEmpty {
                key = "sync:\(syncIdentifier)"
            } else if let identifier = treatment.identifier, !identifier.isEmpty {
                key = "id:\(identifier)"
            } else {
                // Some Nightscout versions omit stable IDs. In that case use
                // every decoded field, not a medically incomplete subset:
                // `amount`, `absolute`, override scale/range, and insulin type
                // can all distinguish treatments that share a timestamp.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = (try? encoder.encode(treatment)) ?? Data()
                key = "document:\(data.base64EncodedString())"
            }
            if seen.insert(key).inserted {
                result.append(treatment)
            }
        }
        return result
    }
}
