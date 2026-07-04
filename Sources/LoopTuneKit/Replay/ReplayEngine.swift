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
            guard intervalSeconds > 0, intervalSeconds <= 20 * 60 else { continue }

            let observedDelta = current.milligramsPerDeciliter - previous.milligramsPerDeciliter
            let insulinDelta = insulinLookup.value(at: current.date) - insulinLookup.value(at: previous.date)
            let carbDelta = carbLookup.value(at: current.date) - carbLookup.value(at: previous.date)
            var deviation = observedDelta - insulinDelta - carbDelta

            // Post-hypo rebound guard: don't count rises below 80 as need.
            if current.milligramsPerDeciliter < 80, deviation > 0 {
                deviation = 0
            }

            let averageDelta = Self.averageDelta(in: sortedGlucose, endingAt: index)
            let iob = iobTimeline.closestPrior(to: current.date)?.value ?? 0
            let cob = carbStatuses.dynamicCarbsOnBoard(at: current.date, absorptionModel: PiecewiseLinearAbsorption())

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

    /// Mean 5-minute glucose delta over the trailing ~20 minutes (oref0's
    /// `avgDelta`): `(BG[i] − BG[i−4]) / 4`, falling back to the single-step
    /// delta near the start of the series.
    static func averageDelta(in glucose: [GlucoseSample], endingAt index: Int) -> Double {
        let lookback = min(4, index)
        guard lookback > 0 else { return 0 }
        let current = glucose[index]
        let past = glucose[index - lookback]
        let spanIntervals = Double(lookback)
        return (current.milligramsPerDeciliter - past.milligramsPerDeciliter) / spanIntervals
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
