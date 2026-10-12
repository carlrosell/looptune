import Foundation
import LoopAlgorithm

/// Replays historical CGM, insulin, and carb data through the Loop algorithm's
/// forward models to produce per-interval glucose *deviations* — the signal the
/// tuner categorizes and sums.
///
/// The deviation for a CGM interval is
/// `observed ΔBG − modeled insulin ΔBG − modeled carb ΔBG`, where the insulin
/// effect uses Loop's exponential model and the carb effect uses Loop's dynamic
/// (ICE-driven) piecewise-linear absorption — exactly the pieces the
/// `LoopAlgorithm` package computes.
public struct ReplayEngine: Sendable {
    /// Insulin model duration Loop uses (6h10m); doses this far before the
    /// window start still contribute effects.
    static let insulinActivityDuration: TimeInterval = InsulinMath.defaultInsulinActivityDuration
    /// Tuning thresholds and oref0 parity are expressed per five-minute datum.
    static let standardInterval: TimeInterval = DeviationSample.standardDuration
    static let maximumCGMGap: TimeInterval = 20 * 60

    public init() {}

    public enum ReplayError: Error, Equatable {
        case insufficientGlucose
        /// A meal logged at this date has an absorption time above
        /// `CarbRecord.maximumAbsorptionTime`, which input retention cannot
        /// keep for its whole modeled span.
        case unsupportedAbsorptionTime(Date)
    }

    /// Compute the deviation timeline over `[analysisStart, analysisEnd]`.
    ///
    /// The caller should supply glucose/doses/carbs that extend *before*
    /// `analysisStart` (by at least the insulin activity duration for doses and
    /// ~20 min for glucose) so effects and deltas at the window start are
    /// well-defined. Only samples whose interval end falls within the analysis
    /// window are returned.
    public func computeDeviations(
        glucose: [GlucoseSample],
        doses: [DoseRecord],
        carbs: [CarbRecord],
        profile: TherapyProfile,
        analysisStart: Date,
        analysisEnd: Date
    ) throws -> [DeviationSample] {
        try computeDeviations(
            glucose: glucose,
            doses: doses,
            carbs: carbs,
            settings: TherapyTimeline(profile: profile),
            analysisStart: analysisStart,
            analysisEnd: analysisEnd
        )
    }

    /// Compute deviations with the settings `settings` records for each
    /// instant, so every dose and meal is modeled with the schedules in force
    /// when it began.
    public func computeDeviations(
        glucose: [GlucoseSample],
        doses: [DoseRecord],
        carbs: [CarbRecord],
        settings: TherapyTimeline,
        analysisStart: Date,
        analysisEnd: Date
    ) throws -> [DeviationSample] {
        let sortedGlucose = glucose.sorted { $0.date < $1.date }
        guard sortedGlucose.count >= 2 else { throw ReplayError.insufficientGlucose }

        // Coverage window for schedule timelines: span every input plus the
        // insulin tail, so LoopAlgorithm's closestPrior lookups never fail.
        let earliestInput = [sortedGlucose.first?.date, doses.map(\.startDate).min(), carbs.map(\.date).min()]
            .compactMap { $0 }.min() ?? analysisStart
        let latestInput = [sortedGlucose.last?.date, doses.map(\.endDate).max(), carbs.map(\.date).max()]
            .compactMap { $0 }.max() ?? analysisEnd
        let scheduleStart = earliestInput.addingTimeInterval(-600)
        let scheduleEnd = max(latestInput, analysisEnd).addingTimeInterval(Self.insulinActivityDuration)

        let basalTimeline = settings.basalTimeline(from: scheduleStart, to: scheduleEnd)
        let isfTimeline = settings.sensitivityTimeline(from: scheduleStart, to: scheduleEnd)
        let crTimeline = settings.carbRatioTimeline(from: scheduleStart, to: scheduleEnd)

        // Convert to LoopAlgorithm types (sorted; unified glucose provenance so
        // ICE intervals are not silently dropped).
        let fixtureGlucose = sortedGlucose.map { $0.fixture(unifyProvenance: true) }
        let fixtureDoses = doses
            .sorted { $0.startDate < $1.startDate }
            .map { $0.fixture(defaultInsulinType: settings.profile(at: $0.startDate).insulinType) }
        let fixtureCarbs = carbs
            .sorted { $0.date < $1.date }
            .map { $0.fixture() }

        // Insulin effects (cumulative mg/dL), netting temps against scheduled basal.
        let annotatedDoses = fixtureDoses.annotated(with: basalTimeline, fillBasalGaps: true)
        let insulinEffects = annotatedDoses.glucoseEffects(insulinSensitivityHistory: isfTimeline)

        // Insulin counteraction, then dynamic carb absorption, then carb effects.
        let ice = fixtureGlucose.counteractionEffects(to: insulinEffects)
        let carbStatuses = fixtureCarbs.map(
            to: ice,
            carbRatio: crTimeline,
            insulinSensitivity: isfTimeline
        )
        let carbEffects = carbStatuses.dynamicGlucoseEffects(
            carbRatios: crTimeline,
            insulinSensitivities: isfTimeline
        )

        let iobTimeline = annotatedDoses.insulinOnBoardTimeline()
        // Precompute the COB timeline once (dynamicCarbsOnBoard(at:) is O(carbs)
        // per call, so calling it per interval would be O(intervals × carbs)).
        let cobTimeline = carbStatuses.dynamicCarbsOnBoard()
        let cobLookup = CarbTimelineLookup(cobTimeline)

        // Cumulative-effect lookups (arrays are on a 5-min grid; closestPrior
        // gives the value at or before a CGM timestamp).
        let insulinLookup = CumulativeEffectLookup(insulinEffects)
        let carbLookup = CumulativeEffectLookup(carbEffects)

        var result: [DeviationSample] = []
        for index in 1..<sortedGlucose.count {
            let current = sortedGlucose[index]
            let previous = sortedGlucose[index - 1]
            guard current.date > analysisStart, current.date <= analysisEnd else { continue }

            // Skip implausible readings / long gaps (mirrors oref0's guards).
            guard current.milligramsPerDeciliter >= 40, previous.milligramsPerDeciliter >= 40 else { continue }
            let intervalSeconds = current.date.timeIntervalSince(previous.date)
            guard intervalSeconds > 0, intervalSeconds <= Self.maximumCGMGap else { continue }

            // CGM cadence varies (one-minute sensors, jitter, missed readings),
            // and the categorizer thresholds are defined in mg/dL per five
            // minutes, so express every change as a five-minute rate. The
            // interval duration travels with the sample: tuners weight sums and
            // evidence by it, so cadence changes neither the rate nor the weight.
            let intervalScale = Self.standardInterval / intervalSeconds
            let observedDelta = (current.milligramsPerDeciliter - previous.milligramsPerDeciliter) * intervalScale
            let insulinDelta = (
                insulinLookup.value(at: current.date) - insulinLookup.value(at: previous.date)
            ) * intervalScale
            let carbDelta = (
                carbLookup.value(at: current.date) - carbLookup.value(at: previous.date)
            ) * intervalScale
            var deviation = observedDelta - insulinDelta - carbDelta

            // Post-hypo rebound guard: don't count rises below 80 as need.
            if current.milligramsPerDeciliter < 80, deviation > 0 {
                deviation = 0
            }

            let averageDelta = Self.averageDelta(in: sortedGlucose, endingAt: index)
            let iob = iobTimeline.closestPrior(to: current.date)?.value ?? 0
            let cob = cobLookup.value(at: current.date)

            result.append(DeviationSample(
                date: current.date,
                glucose: current.milligramsPerDeciliter,
                averageDelta: averageDelta,
                insulinEffect: insulinDelta,
                deviation: deviation,
                insulinOnBoard: iob,
                carbsOnBoard: cob,
                duration: intervalSeconds
            ))
        }
        return result
    }

    /// How long after its start a meal can still absorb in the pinned model:
    /// the entered absorption time stretched by the 1.5× overrun, plus the
    /// ten-minute effect delay (`CarbStatusBuilder.maxEndDate`).
    static func carbAbsorptionSpan(absorptionTime: TimeInterval) -> TimeInterval {
        absorptionTime * CarbMath.defaultAbsorptionTimeOverrun + CarbMath.defaultEffectDelay
    }

    /// Slack after a meal's absorption span before it stops affecting a
    /// window. When observed absorption falls below the modeled minimum, the
    /// model spreads the rest over a span that already includes the delay, so
    /// the effect can end one delay later. The first sample's interval can
    /// begin up to `maximumCGMGap` before the window, and effects are read
    /// from a five-minute grid.
    static let carbRetentionMargin: TimeInterval =
        CarbMath.defaultEffectDelay + maximumCGMGap + GlucoseMath.defaultDelta

    /// How far back each input can influence deviations inside an analysis
    /// window, used to trim inputs before replay (ADR 0008).
    ///
    /// Carbs: a meal with the longest supported absorption time
    /// (`CarbRecord.maximumAbsorptionTime`, 10h) absorbs for 15h10m, so every
    /// meal still active in the window starts within 15h45m of it. Keeping
    /// every meal in that span also keeps earlier meals whose absorption
    /// overlapped an active one, which matters because the model splits
    /// observed absorption among concurrently active meals. A meal that began
    /// before the span is dropped even if it overlapped a retained meal.
    ///
    /// Glucose: the earliest retained meal needs counteraction effects from
    /// its start to attribute its absorption.
    ///
    /// Doses: those counteraction effects need the insulin effect at every
    /// retained glucose sample, so doses are kept eight hours further back.
    /// Doses act for 6h10m after delivery; the remaining 1h50m allows for a
    /// dose still being delivered at the cutoff, as the earlier 18h/10h split
    /// did.
    public static let carbLookback: TimeInterval =
        carbAbsorptionSpan(absorptionTime: CarbRecord.maximumAbsorptionTime) + carbRetentionMargin
    public static let glucoseLookback: TimeInterval = carbLookback
    public static let doseLookback: TimeInterval = glucoseLookback + 8 * 3600

    /// How far before an analysis window replay can read any input. Fetching
    /// derives both its data window and its required profile-history
    /// coverage from this, so it must bound every lookback above.
    public static var inputLookback: TimeInterval {
        max(doseLookback, carbLookback, glucoseLookback)
    }

    /// Trim inputs to the subset that can influence deviations inside
    /// `[analysisStart, analysisEnd]`. Replaying a day window with trimmed
    /// inputs produces the same deviations as replaying with the full dataset,
    /// but costs O(day) instead of O(window) — the difference between linear
    /// and quadratic total work for day-chained runs. Equivalence assumes
    /// absorption times within `CarbRecord.maximumAbsorptionTime`;
    /// `HistoricalReplay` rejects longer ones.
    public static func trimmedInputs(
        glucose: [GlucoseSample],
        doses: [DoseRecord],
        carbs: [CarbRecord],
        analysisStart: Date,
        analysisEnd: Date
    ) -> (glucose: [GlucoseSample], doses: [DoseRecord], carbs: [CarbRecord]) {
        let glucoseStart = analysisStart.addingTimeInterval(-glucoseLookback)
        let doseStart = analysisStart.addingTimeInterval(-doseLookback)
        let carbStart = analysisStart.addingTimeInterval(-carbLookback)
        return (
            glucose.filter { $0.date >= glucoseStart && $0.date <= analysisEnd },
            doses.filter { $0.startDate >= doseStart && $0.startDate <= analysisEnd },
            carbs.filter { $0.date >= carbStart && $0.date <= analysisEnd }
        )
    }

    /// oref0's `avgDelta` horizon: four five-minute intervals.
    static let averageDeltaHorizon: TimeInterval = 4 * standardInterval

    /// Mean five-minute glucose delta over the trailing `averageDeltaHorizon`.
    ///
    /// The horizon is elapsed time, not a reading count, so the same trajectory
    /// gives the same value at any CGM cadence: four readings span 4 minutes of
    /// one-minute CGM but an hour of fifteen-minute CGM. When the horizon falls
    /// between two readings, glucose there is interpolated between them. The
    /// walk back stops at a gap longer than `maximumCGMGap`, so a shorter
    /// contiguous history uses its earliest reading. On a regular five-minute
    /// grid the horizon lands on the fourth prior reading, as in oref0.
    static func averageDelta(in glucose: [GlucoseSample], endingAt index: Int) -> Double {
        guard index > 0, index < glucose.count else { return 0 }
        let current = glucose[index]
        let horizonStart = current.date.addingTimeInterval(-averageDeltaHorizon)
        var startIndex = index
        while startIndex > 0, glucose[startIndex].date > horizonStart {
            let gap = glucose[startIndex].date.timeIntervalSince(glucose[startIndex - 1].date)
            guard gap > 0, gap <= Self.maximumCGMGap else { break }
            startIndex -= 1
        }
        guard startIndex < index else { return 0 }

        var pastDate = glucose[startIndex].date
        var pastGlucose = glucose[startIndex].milligramsPerDeciliter
        if pastDate < horizonStart {
            // The reading after `startIndex` is inside the horizon, and the
            // accepted interval between them spans its start.
            let later = glucose[startIndex + 1]
            let fraction = horizonStart.timeIntervalSince(pastDate) / later.date.timeIntervalSince(pastDate)
            pastGlucose += (later.milligramsPerDeciliter - pastGlucose) * fraction
            pastDate = horizonStart
        }
        let span = current.date.timeIntervalSince(pastDate)
        guard span > 0 else { return 0 }
        return (current.milligramsPerDeciliter - pastGlucose) * Self.standardInterval / span
    }
}

/// Fast lookup of a cumulative effect value at an arbitrary date by linear
/// interpolation between the surrounding 5-minute grid points.
struct CumulativeEffectLookup: Sendable {
    private let effects: [GlucoseEffect]

    init(_ effects: [GlucoseEffect]) {
        self.effects = effects
    }

    /// Interpolated cumulative effect (mg/dL) at `date`. Clamps to the series
    /// endpoints outside the covered range.
    func value(at date: Date) -> Double {
        guard let first = effects.first else { return 0 }
        if date <= first.startDate { return first.quantity.doubleValue(for: .milligramsPerDeciliter) }
        guard let last = effects.last else { return 0 }
        if date >= last.startDate { return last.quantity.doubleValue(for: .milligramsPerDeciliter) }

        // Binary search for the segment [lo, hi] containing date.
        var low = 0
        var high = effects.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if effects[mid].startDate <= date {
                low = mid
            } else {
                high = mid
            }
        }
        let a = effects[low]
        let b = effects[high]
        let span = b.startDate.timeIntervalSince(a.startDate)
        let av = a.quantity.doubleValue(for: .milligramsPerDeciliter)
        let bv = b.quantity.doubleValue(for: .milligramsPerDeciliter)
        guard span > 0 else { return av }
        let fraction = date.timeIntervalSince(a.startDate) / span
        return av + (bv - av) * fraction
    }
}

/// Nearest-prior lookup over a precomputed carbs-on-board (grams) timeline.
struct CarbTimelineLookup: Sendable {
    private let dates: [Date]
    private let grams: [Double]

    init(_ values: [CarbValue]) {
        self.dates = values.map(\.startDate)
        self.grams = values.map(\.value)
    }

    /// COB (g) at or before `date`; 0 before the first sample.
    func value(at date: Date) -> Double {
        guard let first = dates.first else { return 0 }
        if date < first { return 0 }
        // Binary search for the last entry with date <= query.
        var low = 0
        var high = dates.count - 1
        var result = 0.0
        while low <= high {
            let mid = (low + high) / 2
            if dates[mid] <= date {
                result = grams[mid]
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}
