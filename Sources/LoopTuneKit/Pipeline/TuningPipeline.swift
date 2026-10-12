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
        /// Usable evidence was below `minimum`. Both are five-minute intervals;
        /// `actual` counts only complete intervals, so it is below `minimum`.
        case insufficientUsableData(minimum: Int, actual: Int)
        case invalidInput(String)
        /// Nightscout holds more `collection` records between `start` and
        /// `end` than the range queries could retrieve (ADR 0005).
        case incompleteRecords(collection: String, start: Date, end: Date)
        /// The profile history does not reach the settings active at
        /// `requiredFrom`, the earliest instant replay reads (ADR 0005).
        case incompleteProfileHistory(requiredFrom: Date)
    }

    /// One hour of CGM evidence: the smallest evidence set allowed to produce
    /// a user-facing recommendation.
    public static let minimumEvidenceDuration: TimeInterval = 3600
    /// `minimumEvidenceDuration` in five-minute intervals, the unit of every
    /// evidence count. The check itself compares durations, not readings or
    /// rounded counts.
    public static let minimumUsableSamples = Int(minimumEvidenceDuration / DeviationSample.standardDuration)

    /// Records requested by one entries or treatments query.
    static let recordPageSize = 1500
    /// A response at least this long may have been cut off by a server or
    /// proxy cap below the requested count; API v3 and common proxies cap at
    /// 1,000. Such a response is treated like a full one.
    static let possiblyCappedCount = 1000
    /// Queries allowed to retrieve one collection for one day bucket.
    static let maximumQueriesPerDay = 64
    /// Profile documents requested first, doubled until the history covers
    /// the earliest replay input, up to `maximumProfileCount`.
    static let initialProfileCount = 100
    static let maximumProfileCount = 3200
    /// What Nightscout returns when a request's `count` is dropped.
    static let defaultProfileCount = 10

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
        // A therapy change inside the window, or among the retained inputs
        // before it, needs the chained tuner's activation-aware replay. The
        // single-replay path below applies one profile to every input.
        let replayWindow = DateInterval(
            start: inputs.analysisStart.addingTimeInterval(-ReplayEngine.inputLookback),
            end: inputs.analysisEnd
        )
        let hasTherapyChangeInReplay = HistoricalReplay.profileSegments(
            for: replayWindow,
            history: chainInputs.profileHistory
        ).count > 1

        if days > 1 || hasTherapyChangeInReplay {
            let result = try ChainedTuner(options: options).run(inputs: chainInputs)
            // Every tuned segment already holds `minimumEvidenceDuration`, so
            // this rejects only a run in which no segment was tuned.
            guard result.output.totalSamples >= Self.minimumUsableSamples else {
                throw PipelineError.insufficientUsableData(
                    minimum: Self.minimumUsableSamples,
                    actual: result.output.totalSamples
                )
            }
            return try TuningRecommendation(
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
        let usableEvidence = DeviationSample.fiveMinuteIntervals(of: deviations)
        let usableDuration = DeviationSample.totalDuration(of: deviations)
        guard usableDuration >= Self.minimumEvidenceDuration else {
            throw PipelineError.insufficientUsableData(
                minimum: Self.minimumUsableSamples,
                actual: DeviationSample.completeFiveMinuteIntervals(in: usableDuration)
            )
        }

        let tuner = LoopTuner(options: options)
        let attributionStart = inputs.analysisStart.addingTimeInterval(-ReplayEngine.carbLookback)
        let output = try tuner.tune(
            deviations: deviations,
            carbs: inputs.eligibleCarbs(from: inputs.analysisStart, to: inputs.analysisEnd),
            attributionCarbs: inputs.carbs.filter {
                $0.date >= attributionStart && $0.date <= inputs.analysisEnd
            },
            currentProfile: profile,
            pumpProfile: profile,
            analysisStart: inputs.analysisStart,
            analysisEnd: inputs.analysisEnd
        )

        return try TuningRecommendation(
            from: output,
            daysAnalyzed: days,
            profileGlucoseUnit: profile.glucoseUnit,
            excludedOverrideSamples: DeviationSample.fiveMinuteIntervals(of: allDeviations) - usableEvidence
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
        guard inputs.carbs.allSatisfy({
            $0.absorptionTime <= CarbRecord.maximumAbsorptionTime
        }) else { throw PipelineError.invalidInput("carb absorption time") }
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
        let diagnostics = try await DiagnosticsBuilder().build(
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
    /// The window is tiled with UTC day buckets (plus a lead-in covering the
    /// replay lookback, and a trailing margin covering the carb-ratio
    /// timeline). With a `cache`, each finished bucket is served from disk
    /// when available and stored after fetching; the current (unfinished)
    /// day is always fetched live and never stored.
    ///
    /// Every record in each bucket and the profile active at the earliest
    /// replay input are retrieved, or the fetch throws `incompleteRecords` or
    /// `incompleteProfileHistory` (ADR 0005).
    public func fetchInputs(
        client: NightscoutClient,
        configuration: TuningConfiguration,
        endingAt end: Date,
        cache: DayCache? = nil
    ) async throws -> TuningInputs {
        let analysisStart = end.addingTimeInterval(-Double(configuration.days) * 86_400)
        let earliestReplayInput = analysisStart.addingTimeInterval(-ReplayEngine.inputLookback)

        // Profile history: always fetched fresh. Loop uploads a new document on
        // every settings change, so the history lets each day replay against
        // the settings that were actually active then.
        let profileDocs = try await Self.fetchProfiles(client: client, coveringFrom: earliestReplayInput)
        guard !profileDocs.isEmpty else { throw PipelineError.noProfile }
        let history = try ProfileIngest.makeHistory(from: profileDocs)
        var profile = history.current
        if profile.insulinType == nil { profile.insulinType = configuration.insulinType }

        cache?.pruneExpired()

        // One lead-in day covers `ReplayEngine.inputLookback` (23h45m of
        // doses), the 15h45m carb and glucose lookback, and the 30-min glucose
        // delta lead; 6h trailing margin covers carb-ratio coverage.
        let fetchStart = analysisStart.addingTimeInterval(-max(DayCache.dayLength, ReplayEngine.inputLookback))
        let fetchEnd = end.addingTimeInterval(6 * 3600)
        let buckets = DayCache.utcDayBuckets(covering: fetchStart, to: fetchEnd)

        var entries: [NSEntry] = []
        var treatments: [NSTreatment] = []
        for bucket in buckets {
            // Days cached before completeness was recorded may be truncated.
            if let cache, let cached = cache.load(origin: client.origin, dayKey: bucket.key), cached.isComplete {
                entries += cached.entries
                treatments += cached.treatments
                continue
            }
            let dayEntries = try await Self.fetchAll(
                collection: "entries",
                in: bucket.interval,
                stepsPerSecond: NightscoutClient.entriesRangeStepsPerSecond,
                key: Self.entryKey
            ) { start, end, count in
                try await client.fetchEntries(from: start, to: end, count: count)
            }
            let dayTreatments = try await Self.fetchAll(
                collection: "treatments",
                in: bucket.interval,
                stepsPerSecond: NightscoutClient.treatmentsRangeStepsPerSecond,
                key: Self.treatmentKey
            ) { start, end, count in
                try await client.fetchTreatments(from: start, to: end, count: count)
            }
            entries += dayEntries
            treatments += dayTreatments
            if let cache, cache.shouldStore(dayEnd: bucket.interval.end) {
                cache.store(
                    CachedDay(
                        day: bucket.key,
                        fetchedAt: Date(),
                        entries: dayEntries,
                        treatments: dayTreatments,
                        isComplete: true
                    ),
                    origin: client.origin
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

    /// Profile documents, newest first, reaching back to the one active at
    /// `boundary` when the site has it. The endpoint accepts only `count` and
    /// returns the newest documents by `startDate`, so a full response is
    /// requested again with a larger count until it covers `boundary` or
    /// comes back short, which means the site has no older documents.
    static func fetchProfiles(
        client: NightscoutClient,
        coveringFrom boundary: Date
    ) async throws -> [NSProfileDocument] {
        var count = initialProfileCount
        while true {
            let documents = try await client.fetchProfiles(count: count)
            if covers(documents, boundary) {
                return documents
            }
            if documents.count < count {
                guard try await isWholeProfileHistory(documents, client: client) else {
                    throw PipelineError.incompleteProfileHistory(requiredFrom: boundary)
                }
                return documents
            }
            guard count < maximumProfileCount else {
                throw PipelineError.incompleteProfileHistory(requiredFrom: boundary)
            }
            count = min(count * 2, maximumProfileCount)
        }
    }

    /// Whether a response shorter than requested is the site's whole profile
    /// history. A server that drops `count` returns Nightscout's default of
    /// 10, and a capped one returns its cap, so neither length proves the
    /// history ends there. Ten documents are accepted once a smaller request
    /// shows that `count` is honored.
    static func isWholeProfileHistory(
        _ documents: [NSProfileDocument],
        client: NightscoutClient
    ) async throws -> Bool {
        if documents.count >= possiblyCappedCount {
            return false
        }
        if documents.count == defaultProfileCount {
            return try await client.fetchProfiles(count: 1).count < defaultProfileCount
        }
        return true
    }

    /// Whether a full profile response shows the settings active at
    /// `boundary`. Documents sharing the oldest returned start date may have
    /// been cut off at the limit, so only a newer one at or before `boundary`
    /// proves it.
    static func covers(_ documents: [NSProfileDocument], _ boundary: Date) -> Bool {
        let starts = documents.compactMap(\.startDate)
        guard let oldest = starts.min() else { return false }
        return starts.contains { $0 > oldest && $0 <= boundary }
    }

    /// Every record in `interval` from a range query capped at `pageSize`.
    /// A response that fills the page, or holds at least `possiblyCapped`
    /// records, may be truncated, so its range is split in two and both
    /// halves are queried again, newer half first. The halves share their
    /// inclusive midpoint, and records returned twice are dropped by `key`. This relies only on the range filter and `count`, not on
    /// which matches the server returns first. Bounds lie on the filter's
    /// `stepsPerSecond` grid; a full range that cannot be split, or running
    /// out of queries, throws `incompleteRecords`.
    static func fetchAll<Record>(
        collection: String,
        in interval: DateInterval,
        stepsPerSecond: Double,
        pageSize: Int = recordPageSize,
        possiblyCapped: Int = possiblyCappedCount,
        maximumQueries: Int = maximumQueriesPerDay,
        key: (Record) -> String,
        fetch: (Date, Date, Int) async throws -> [Record]
    ) async throws -> [Record] {
        func date(_ step: Int64) -> Date {
            Date(timeIntervalSince1970: Double(step) / stepsPerSecond)
        }
        var pending = [(
            low: Int64((interval.start.timeIntervalSince1970 * stepsPerSecond).rounded(.down)),
            high: Int64((interval.end.timeIntervalSince1970 * stepsPerSecond).rounded(.up))
        )]
        var pages: [[Record]] = []
        var queries = 0
        while let range = pending.popLast() {
            guard queries < maximumQueries else {
                throw PipelineError.incompleteRecords(collection: collection, start: interval.start, end: interval.end)
            }
            queries += 1
            let page = try await fetch(date(range.low), date(range.high), pageSize)
            guard page.count >= min(pageSize, possiblyCapped) else {
                pages.append(page)
                continue
            }
            guard range.high - range.low >= 2 else {
                throw PipelineError.incompleteRecords(
                    collection: collection,
                    start: date(range.low),
                    end: date(range.high)
                )
            }
            let middle = range.low + (range.high - range.low) / 2
            pending.append((range.low, middle))
            pending.append((middle, range.high))
        }
        guard pages.count > 1 else { return pages.first ?? [] }
        return dedupe(pages.flatMap { $0 }, key: key)
    }

    /// Nightscout range queries are inclusive at both ends, so a document with
    /// a timestamp exactly on a bucket boundary appears in two buckets. Drop
    /// exact duplicates before ingestion (boluses would otherwise double).
    static func dedupeAcrossBuckets(_ treatments: [NSTreatment]) -> [NSTreatment] {
        dedupe(treatments, key: treatmentKey)
    }

    static func dedupe<Record>(_ records: [Record], key: (Record) -> String) -> [Record] {
        var seen = Set<String>()
        return records.filter { seen.insert(key($0)).inserted }
    }

    static func treatmentKey(_ treatment: NSTreatment) -> String {
        if let syncIdentifier = treatment.syncIdentifier, !syncIdentifier.isEmpty {
            return "sync:\(syncIdentifier)"
        }
        if let identifier = treatment.identifier, !identifier.isEmpty {
            return "id:\(identifier)"
        }
        // Some Nightscout versions omit stable IDs. In that case use every
        // decoded field, not a medically incomplete subset: `amount`,
        // `absolute`, override scale/range, and insulin type can all
        // distinguish treatments that share a timestamp.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(treatment)) ?? Data()
        return "document:\(data.base64EncodedString())"
    }

    /// Entries carry no stable ID, so every decoded field is the key.
    static func entryKey(_ entry: NSEntry) -> String {
        [
            String(entry.date.timeIntervalSince1970.bitPattern),
            String(entry.sgv.bitPattern),
            String(reflecting: entry.type),
            String(reflecting: entry.device),
        ].joined(separator: "|")
    }
}
