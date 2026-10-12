import Foundation

/// The result of a multi-day chained tuning run.
public struct ChainedTuningResult: Sendable, Equatable {
    /// The final tuned output. Pump values are the fixed pump baseline;
    /// `categoryCounts`, `totalSamples`, and `basalSampleCountByHour` are
    /// accumulated across the chained days since the last settings change.
    public var output: TuningOutput
    /// Per basal hour, the number of day windows since the last settings change
    /// in which that hour received no tuning data (AutotuneWeb's "days missing"
    /// confidence signal).
    public var daysMissingByHour: [Int]
    /// Number of day windows since the last settings change that were tuned.
    public var daysTuned: Int
    /// ISF after each chained day since the last settings change (trajectory,
    /// oldest → newest).
    public var dailyISF: [Double]
    /// Carb ratio after each chained day since the last settings change.
    public var dailyCarbRatio: [Double]
    /// Instants within the window where the user actually changed therapy
    /// settings (from the profile history); the tuning iteration restarted from
    /// the applied settings at each, discarding earlier output and evidence.
    public var settingsChanges: [Date] = []
    /// Replay samples excluded because a temporary override changed insulin
    /// needs at that instant.
    public var excludedOverrideSamples: Int = 0
}

/// Runs tuning day-by-day over a multi-day window, feeding each day's tuned
/// profile into the next day's replay — oref0-autotune's chaining model. The
/// pump profile stays fixed as the safety-cap baseline, so total drift is
/// bounded regardless of how many days are chained, and the 20% per-run step
/// yields an implicit exponential recency weighting. The tuned profile stands
/// in for the settings period it was tuned under; inputs that began before
/// that period's activation keep their recorded settings in replay.
///
/// Day boundaries fall at 04:00 local (oref0's convention: a "day" runs 4am to
/// 4am so overnight periods aren't split).
public struct ChainedTuner: Sendable {
    let caps: TuningCaps
    let options: CategorizerOptions

    /// Local hour at which one tuning day ends and the next begins.
    public static let dayBoundaryHour = 4
    /// Minimum evidence, in five-minute intervals, for a window to count as
    /// tuned (1 hour).
    static let minimumSamplesPerDay = TuningPipeline.minimumUsableSamples

    public init(caps: TuningCaps = TuningCaps(), options: CategorizerOptions = CategorizerOptions()) {
        self.caps = caps
        self.options = options
    }

    public func run(inputs: TuningInputs) throws -> ChainedTuningResult {
        // Caps and the recommendation baseline are always the CURRENT profile —
        // the output answers "what should I change from what's in Loop now".
        let pumpProfile = inputs.profile

        let replay = HistoricalReplay(inputs: inputs)

        // The replay/tuning baseline starts from the settings that were
        // actually active at the window start (when history is available).
        var activeHistorical = replay.recordedProfile(at: inputs.analysisStart)
        var evolving = activeHistorical
        var settingsChanges: [Date] = []

        let sensitivityTuningEntries = SensitivityTuner.tuningEntries(for: pumpProfile.sensitivitySchedule)
        let freshEpoch = Epoch(
            sensitivityEntryCount: sensitivityTuningEntries.count,
            carbRatioEntryCount: pumpProfile.carbRatioSchedule.entries.count
        )
        var epoch = freshEpoch
        let tuner = LoopTuner(caps: caps, options: options)

        var excludedOverrideSamples = 0

        for window in replay.segmentsByDay() {
            var windowHadTuning = false
            var tunedHoursInWindow = [Bool](repeating: false, count: 24)
            var tunedSensitivityInWindow = [Bool](repeating: false, count: epoch.sensitivityDaysMissing.count)
            var tunedCarbRatioInWindow = [Bool](repeating: false, count: epoch.carbRatioDaysMissing.count)

            // A settings change can occur at any instant, not only at a 04:00
            // day boundary. Split the day at every profile activation so
            // neither replay nor tuning attributes data to the wrong settings.
            for segment in window {
                if !segment.recorded.hasSameTherapySettings(as: activeHistorical) {
                    evolving = segment.recorded
                    activeHistorical = segment.recorded
                    settingsChanges.append(segment.recorded.activeFrom ?? segment.interval.start)
                    // Output and evidence from the previous settings cannot
                    // support a recommendation for the new ones, including
                    // tuning earlier in this window.
                    epoch = freshEpoch
                    windowHadTuning = false
                    tunedHoursInWindow = [Bool](repeating: false, count: 24)
                    tunedSensitivityInWindow = [Bool](repeating: false, count: tunedSensitivityInWindow.count)
                    tunedCarbRatioInWindow = [Bool](repeating: false, count: tunedCarbRatioInWindow.count)
                }

                // The evolving profile replaces this settings period from its
                // activation; earlier inputs keep their recorded settings.
                let replayed = try replay.replay(segment, candidate: evolving)
                let deviations = replayed.eligibleDeviations
                let usableEvidence = DeviationSample.fiveMinuteIntervals(of: deviations)
                excludedOverrideSamples += DeviationSample.fiveMinuteIntervals(of: replayed.deviations) - usableEvidence
                guard usableEvidence >= Self.minimumSamplesPerDay else { continue }

                let output = try tuner.tune(
                    deviations: deviations,
                    carbs: inputs.eligibleCarbs(from: segment.interval.start, to: segment.interval.end),
                    attributionCarbs: replayed.retainedCarbs,
                    currentProfile: evolving,
                    pumpProfile: pumpProfile,
                    analysisStart: segment.interval.start,
                    analysisEnd: segment.interval.end
                )

                for hour in 0..<24 {
                    if !output.untunedBasalHours[hour] {
                        tunedHoursInWindow[hour] = true
                    }
                    epoch.sampleCountByHour[hour] += output.basalSampleCountByHour[hour]
                }
                for index in output.sensitivitySchedule.indices {
                    epoch.sensitivityEvidence[index] += output.sensitivitySchedule[index].evidenceCount
                    if !output.sensitivitySchedule[index].untuned {
                        tunedSensitivityInWindow[index] = true
                    }
                }
                for index in output.carbRatioSchedule.indices {
                    epoch.carbRatioEvidence[index] += output.carbRatioSchedule[index].evidenceCount
                    if !output.carbRatioSchedule[index].untuned {
                        tunedCarbRatioInWindow[index] = true
                    }
                }
                for (category, count) in output.categoryCounts {
                    epoch.categoryCounts[category, default: 0] += count
                }
                epoch.totalSamples += output.totalSamples
                windowHadTuning = true
                epoch.lastOutput = output

                evolving = try evolving.replacing(
                    basalHourly: output.tunedBasalHourly,
                    sensitivitySchedule: output.tunedSensitivityDailySchedule(),
                    carbRatioSchedule: output.tunedCarbRatioDailySchedule()
                )
            }

            epoch.windows += 1
            for hour in 0..<24 where !tunedHoursInWindow[hour] {
                epoch.daysMissing[hour] += 1
            }
            for index in tunedSensitivityInWindow.indices where !tunedSensitivityInWindow[index] {
                epoch.sensitivityDaysMissing[index] += 1
            }
            for index in tunedCarbRatioInWindow.indices where !tunedCarbRatioInWindow[index] {
                epoch.carbRatioDaysMissing[index] += 1
            }
            if windowHadTuning {
                epoch.daysTuned += 1
                epoch.dailyISF.append(evolving.sensitivitySchedule.timeWeightedAverage())
                epoch.dailyCR.append(evolving.carbRatioSchedule.timeWeightedAverage())
            }
        }

        let totalWindows = epoch.windows
        guard var final = epoch.lastOutput else {
            // No tunable segment under the final settings: recommend the pump
            // settings unchanged with no evidence, which the pipeline reports
            // as insufficient data.
            let pumpHourly = pumpProfile.basalSchedule.hourlyValues()
            let output = try TuningOutput(
                tunedBasalHourly: pumpHourly,
                pumpBasalHourly: pumpHourly,
                untunedBasalHours: Array(repeating: true, count: 24),
                sensitivitySchedule: sensitivityTuningEntries.map {
                    ScheduleTuningOutput(
                        secondsSinceMidnight: $0.secondsSinceMidnight,
                        tunedValue: $0.value,
                        pumpValue: $0.value,
                        untuned: true,
                        daysMissing: totalWindows
                    )
                },
                carbRatioSchedule: pumpProfile.carbRatioSchedule.entries.map {
                    ScheduleTuningOutput(
                        secondsSinceMidnight: $0.secondsSinceMidnight,
                        tunedValue: $0.value,
                        pumpValue: $0.value,
                        untuned: true,
                        daysMissing: totalWindows
                    )
                },
                categoryCounts: [:],
                totalSamples: 0
            )
            return ChainedTuningResult(
                output: output,
                daysMissingByHour: epoch.daysMissing,
                daysTuned: 0,
                dailyISF: [],
                dailyCarbRatio: [],
                settingsChanges: settingsChanges,
                excludedOverrideSamples: excludedOverrideSamples
            )
        }

        // Present accumulated coverage on the final output. An hour counts as
        // untuned overall only if it was missing on every window of the epoch.
        final.categoryCounts = epoch.categoryCounts
        final.totalSamples = epoch.totalSamples
        final.basalSampleCountByHour = epoch.sampleCountByHour
        final.untunedBasalHours = epoch.daysMissing.map { $0 >= totalWindows }
        for index in final.sensitivitySchedule.indices {
            final.sensitivitySchedule[index].evidenceCount = epoch.sensitivityEvidence[index]
            final.sensitivitySchedule[index].daysMissing = epoch.sensitivityDaysMissing[index]
            final.sensitivitySchedule[index].untuned = epoch.sensitivityDaysMissing[index] >= totalWindows
        }
        for index in final.carbRatioSchedule.indices {
            final.carbRatioSchedule[index].evidenceCount = epoch.carbRatioEvidence[index]
            final.carbRatioSchedule[index].daysMissing = epoch.carbRatioDaysMissing[index]
            final.carbRatioSchedule[index].untuned = epoch.carbRatioDaysMissing[index] >= totalWindows
        }

        return ChainedTuningResult(
            output: final,
            daysMissingByHour: epoch.daysMissing,
            daysTuned: epoch.daysTuned,
            dailyISF: epoch.dailyISF,
            dailyCarbRatio: epoch.dailyCR,
            settingsChanges: settingsChanges,
            excludedOverrideSamples: excludedOverrideSamples
        )
    }

    /// Output and evidence accumulated under one set of applied therapy
    /// settings. A settings change starts a new epoch, so only evidence gathered
    /// under the final settings can support the returned recommendation.
    private struct Epoch {
        var lastOutput: TuningOutput?
        /// Day windows (or the partial window from the change) in this epoch.
        var windows = 0
        var daysMissing = [Int](repeating: 0, count: 24)
        var sampleCountByHour = [Int](repeating: 0, count: 24)
        var sensitivityDaysMissing: [Int]
        var carbRatioDaysMissing: [Int]
        var sensitivityEvidence: [Int]
        var carbRatioEvidence: [Int]
        var categoryCounts: [DeviationCategory: Int] = [:]
        var totalSamples = 0
        var daysTuned = 0
        var dailyISF: [Double] = []
        var dailyCR: [Double] = []

        init(sensitivityEntryCount: Int, carbRatioEntryCount: Int) {
            sensitivityDaysMissing = [Int](repeating: 0, count: sensitivityEntryCount)
            carbRatioDaysMissing = [Int](repeating: 0, count: carbRatioEntryCount)
            sensitivityEvidence = [Int](repeating: 0, count: sensitivityEntryCount)
            carbRatioEvidence = [Int](repeating: 0, count: carbRatioEntryCount)
        }
    }
}
