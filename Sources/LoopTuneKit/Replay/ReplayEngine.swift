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
    static let standardInterval: TimeInterval = 5 * 60
    static let maximumCGMGap: TimeInterval = 20 * 60

    public init() {}

    public enum ReplayError: Error, Equatable {
        case insufficientGlucose
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

        let basalTimeline = profile.basalTimeline(from: scheduleStart, to: scheduleEnd)
        let isfTimeline = profile.sensitivityTimeline(from: scheduleStart, to: scheduleEnd)
        let crTimeline = profile.carbRatioTimeline(from: scheduleStart, to: scheduleEnd)

        // Convert to LoopAlgorithm types (sorted; unified glucose provenance so
        // ICE intervals are not silently dropped).
        let fixtureGlucose = sortedGlucose.map { $0.fixture(unifyProvenance: true) }
        let fixtureDoses = doses
            .sorted { $0.startDate < $1.startDate }
            .map { $0.fixture(defaultInsulinType: profile.insulinType) }
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

            // Nightscout timestamps have jitter and can occasionally miss one or
            // more readings. The tuner and categorizer thresholds are defined in
            // mg/dL per five minutes, so normalize every accepted interval rather
            // than counting (for example) a 15-minute change at triple weight.
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
                carbsOnBoard: cob
            ))
        }
        return result
    }

    /// How far back each input can physically influence deviations inside an
    /// analysis window, used to trim inputs before replay. Doses act for the
    /// insulin activity duration (6h10m; padded to oref0's 18h convention);
    /// carbs absorb for at most 10h (`CarbMath.maximumAbsorptionTimeInterval`);
    /// glucose is needed 10h back so carbs started before the window still get
    /// their counteraction-effect attribution.
    public static let doseLookback: TimeInterval = 18 * 3600
    public static let carbLookback: TimeInterval = 10 * 3600
    public static let glucoseLookback: TimeInterval = 10 * 3600

    /// Trim inputs to the subset that can influence deviations inside
    /// `[analysisStart, analysisEnd]`. Replaying a day window with trimmed
    /// inputs produces the same deviations as replaying with the full dataset,
    /// but costs O(day) instead of O(window) — the difference between linear
    /// and quadratic total work for day-chained runs.
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

    /// Mean five-minute glucose delta over up to four contiguous recent
    /// intervals. Uses elapsed time rather than sample count so timestamp jitter
    /// and short missing-sample gaps do not change the unit.
    static func averageDelta(in glucose: [GlucoseSample], endingAt index: Int) -> Double {
        guard index > 0, index < glucose.count else { return 0 }
        var startIndex = index
        var acceptedIntervals = 0
        while startIndex > 0, acceptedIntervals < 4 {
            let gap = glucose[startIndex].date.timeIntervalSince(glucose[startIndex - 1].date)
            guard gap > 0, gap <= Self.maximumCGMGap else { break }
            startIndex -= 1
            acceptedIntervals += 1
        }
        guard startIndex < index else { return 0 }
        let current = glucose[index]
        let past = glucose[startIndex]
        let span = current.date.timeIntervalSince(past.date)
        guard span > 0 else { return 0 }
        return (current.milligramsPerDeciliter - past.milligramsPerDeciliter)
            * Self.standardInterval / span
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
