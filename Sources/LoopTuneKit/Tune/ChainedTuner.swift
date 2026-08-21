import Foundation

/// The result of a multi-day chained tuning run.
public struct ChainedTuningResult: Sendable, Equatable {
    /// The final tuned output. Pump values are the fixed pump baseline;
    /// `categoryCounts`, `totalSamples`, and `basalSampleCountByHour` are
    /// accumulated across all chained days.
    public var output: TuningOutput
    /// Per basal hour, the number of day windows in which that hour received no
    /// tuning data (AutotuneWeb's "days missing" confidence signal).
    public var daysMissingByHour: [Int]
    /// Number of day windows that were actually tuned.
    public var daysTuned: Int
    /// ISF after each chained day (trajectory, oldest → newest).
    public var dailyISF: [Double]
    /// Carb ratio after each chained day.
    public var dailyCarbRatio: [Double]
    /// Instants within the window where the user actually changed therapy
    /// settings (from the profile history); the tuning iteration restarted from
    /// the applied settings at each.
    public var settingsChanges: [Date] = []
    /// Replay samples excluded because a temporary override changed insulin
    /// needs at that instant.
    public var excludedOverrideSamples: Int = 0
}

/// Runs tuning day-by-day over a multi-day window, feeding each day's tuned
/// profile into the next day's replay — oref0-autotune's chaining model. The
/// pump profile stays fixed as the safety-cap baseline, so total drift is
/// bounded regardless of how many days are chained, and the 20% per-run step
/// yields an implicit exponential recency weighting.
///
/// Day boundaries fall at 04:00 local (oref0's convention: a "day" runs 4am to
/// 4am so overnight periods aren't split).
public struct ChainedTuner: Sendable {
    let caps: TuningCaps
    let options: CategorizerOptions

    /// Local hour at which one tuning day ends and the next begins.
    public static let dayBoundaryHour = 4
    /// Minimum deviation samples for a window to count as tuned (1 hour).
    static let minimumSamplesPerDay = 12

    public init(caps: TuningCaps = TuningCaps(), options: CategorizerOptions = CategorizerOptions()) {
        self.caps = caps
        self.options = options
    }

    public func run(inputs: TuningInputs) throws -> ChainedTuningResult {
        // Caps and the recommendation baseline are always the CURRENT profile —
        // the output answers "what should I change from what's in Loop now".
        let pumpProfile = inputs.profile

        let windows = Self.dayWindows(
            from: inputs.analysisStart,
            to: inputs.analysisEnd,
            timeZone: pumpProfile.timeZone
        )

        // The replay/tuning baseline starts from the settings that were
        // actually active at the window start (when history is available).
        var activeHistorical = inputs.profileHistory?.activeProfile(at: inputs.analysisStart) ?? inputs.profile
        var evolving = activeHistorical
        var settingsChanges: [Date] = []

        var daysMissing = [Int](repeating: 0, count: 24)
        var sampleCountByHour = [Int](repeating: 0, count: 24)
        var sensitivityDaysMissing = [Int](repeating: 0, count: pumpProfile.sensitivitySchedule.entries.count)
        var carbRatioDaysMissing = [Int](repeating: 0, count: pumpProfile.carbRatioSchedule.entries.count)
        var sensitivityEvidence = [Int](repeating: 0, count: pumpProfile.sensitivitySchedule.entries.count)
        var carbRatioEvidence = [Int](repeating: 0, count: pumpProfile.carbRatioSchedule.entries.count)
        var mergedCategoryCounts: [DeviationCategory: Int] = [:]
        var totalSamples = 0
        var daysTuned = 0
        var dailyISF: [Double] = []
        var dailyCR: [Double] = []
        var lastOutput: TuningOutput?
        let tuner = LoopTuner(caps: caps, options: options)
        let replay = ReplayEngine()

        var excludedOverrideSamples = 0

        for window in windows {
            var windowHadTuning = false
            var tunedHoursInWindow = [Bool](repeating: false, count: 24)
            var tunedSensitivityInWindow = [Bool](repeating: false, count: sensitivityDaysMissing.count)
            var tunedCarbRatioInWindow = [Bool](repeating: false, count: carbRatioDaysMissing.count)

            // A settings change can occur at any instant, not only at a 04:00
            // day boundary. Split the day at every profile activation so
            // neither replay nor tuning attributes data to the wrong settings.
            for segment in Self.profileSegments(for: window, history: inputs.profileHistory) {
                if let history = inputs.profileHistory {
                    let nowActive = history.activeProfile(at: segment.start)
                    if !nowActive.hasSameTherapySettings(as: activeHistorical) {
                        evolving = nowActive
                        activeHistorical = nowActive
                        settingsChanges.append(nowActive.activeFrom ?? segment.start)
                    }
                }

                // Trim to the inputs that can influence this segment: replaying
                // with the full multi-day dataset would make chaining quadratic.
                let trimmed = ReplayEngine.trimmedInputs(
                    glucose: inputs.glucose,
                    doses: inputs.doses,
                    carbs: inputs.carbs,
                    analysisStart: segment.start,
                    analysisEnd: segment.end
                )
                let allDeviations: [DeviationSample]
                do {
                    allDeviations = try replay.computeDeviations(
                        glucose: trimmed.glucose,
                        doses: trimmed.doses,
                        carbs: trimmed.carbs,
                        profile: evolving,
                        analysisStart: segment.start,
                        analysisEnd: segment.end
                    )
                } catch ReplayEngine.ReplayError.insufficientGlucose {
                    allDeviations = []
                }
                let deviations = inputs.eligibleDeviations(allDeviations)
                excludedOverrideSamples += allDeviations.count - deviations.count
                guard deviations.count >= Self.minimumSamplesPerDay else { continue }

                let output = try tuner.tune(
                    deviations: deviations,
                    carbs: inputs.eligibleCarbs(from: segment.start, to: segment.end),
                    currentProfile: evolving,
                    pumpProfile: pumpProfile,
                    analysisStart: segment.start,
                    analysisEnd: segment.end
                )

                for hour in 0..<24 {
                    if !output.untunedBasalHours[hour] {
                        tunedHoursInWindow[hour] = true
                    }
                    sampleCountByHour[hour] += output.basalSampleCountByHour[hour]
                }
                for index in output.sensitivitySchedule.indices {
                    sensitivityEvidence[index] += output.sensitivitySchedule[index].evidenceCount
                    if !output.sensitivitySchedule[index].untuned {
                        tunedSensitivityInWindow[index] = true
                    }
                }
                for index in output.carbRatioSchedule.indices {
                    carbRatioEvidence[index] += output.carbRatioSchedule[index].evidenceCount
                    if !output.carbRatioSchedule[index].untuned {
                        tunedCarbRatioInWindow[index] = true
                    }
                }
                for (category, count) in output.categoryCounts {
                    mergedCategoryCounts[category, default: 0] += count
                }
                totalSamples += output.totalSamples
                windowHadTuning = true
                lastOutput = output

                evolving = try evolving.replacing(
                    basalHourly: output.tunedBasalHourly,
                    sensitivitySchedule: output.tunedSensitivityDailySchedule(),
                    carbRatioSchedule: output.tunedCarbRatioDailySchedule()
                )
            }

            for hour in 0..<24 where !tunedHoursInWindow[hour] {
                daysMissing[hour] += 1
            }
            for index in tunedSensitivityInWindow.indices where !tunedSensitivityInWindow[index] {
                sensitivityDaysMissing[index] += 1
            }
            for index in tunedCarbRatioInWindow.indices where !tunedCarbRatioInWindow[index] {
                carbRatioDaysMissing[index] += 1
            }
            if windowHadTuning {
                daysTuned += 1
                dailyISF.append(evolving.sensitivitySchedule.timeWeightedAverage())
                dailyCR.append(evolving.carbRatioSchedule.timeWeightedAverage())
            }
        }

        let totalWindows = windows.count
        guard var final = lastOutput else {
            // No tunable day at all: recommend the pump settings unchanged.
            let pumpHourly = pumpProfile.basalSchedule.hourlyValues()
            let output = try TuningOutput(
                tunedBasalHourly: pumpHourly,
                pumpBasalHourly: pumpHourly,
                untunedBasalHours: Array(repeating: true, count: 24),
                sensitivitySchedule: pumpProfile.sensitivitySchedule.entries.map {
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
                daysMissingByHour: daysMissing,
                daysTuned: 0,
                dailyISF: [],
                dailyCarbRatio: [],
                settingsChanges: settingsChanges,
                excludedOverrideSamples: excludedOverrideSamples
            )
        }

        // Present accumulated coverage on the final output. An hour counts as
        // untuned overall only if it was missing on every window.
        final.categoryCounts = mergedCategoryCounts
        final.totalSamples = totalSamples
        final.basalSampleCountByHour = sampleCountByHour
        final.untunedBasalHours = daysMissing.map { $0 >= totalWindows }
        for index in final.sensitivitySchedule.indices {
            final.sensitivitySchedule[index].evidenceCount = sensitivityEvidence[index]
            final.sensitivitySchedule[index].daysMissing = sensitivityDaysMissing[index]
            final.sensitivitySchedule[index].untuned = sensitivityDaysMissing[index] >= totalWindows
        }
        for index in final.carbRatioSchedule.indices {
            final.carbRatioSchedule[index].evidenceCount = carbRatioEvidence[index]
            final.carbRatioSchedule[index].daysMissing = carbRatioDaysMissing[index]
            final.carbRatioSchedule[index].untuned = carbRatioDaysMissing[index] >= totalWindows
        }

        return ChainedTuningResult(
            output: final,
            daysMissingByHour: daysMissing,
            daysTuned: daysTuned,
            dailyISF: dailyISF,
            dailyCarbRatio: dailyCR,
            settingsChanges: settingsChanges,
            excludedOverrideSamples: excludedOverrideSamples
        )
    }

    /// Split a day window at each activation that changes replay-relevant
    /// therapy. Target-only or other metadata uploads do not fragment the
    /// evidence into smaller tuning segments.
    static func profileSegments(
        for window: DateInterval,
        history: ProfileHistory?
    ) -> [DateInterval] {
        var changes: [Date] = []
        if let history {
            var previous = history.activeProfile(at: window.start)
            let candidates = Set(history.timeline.compactMap(\.activeFrom).filter {
                $0 > window.start && $0 < window.end
            }).sorted()
            for date in candidates {
                let active = history.activeProfile(at: date)
                if !active.hasSameTherapySettings(as: previous) {
                    changes.append(date)
                }
                previous = active
            }
        }
        let cuts = ([window.start] + changes + [window.end]).sorted()
        var segments: [DateInterval] = []
        for index in 0..<(cuts.count - 1) where cuts[index] < cuts[index + 1] {
            segments.append(DateInterval(start: cuts[index], end: cuts[index + 1]))
        }
        return segments
    }

    /// Split `[start, end]` into windows cut at 04:00 local. The first and last
    /// windows may be partial. Windows shorter than 30 minutes are dropped.
    static func dayWindows(from start: Date, to end: Date, timeZone: TimeZone) -> [DateInterval] {
        guard start < end else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var boundaries: [Date] = []
        var day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: start)) ?? start
        while day <= end {
            if let boundary = calendar.date(bySettingHour: Self.dayBoundaryHour, minute: 0, second: 0, of: day),
               boundary > start, boundary < end {
                boundaries.append(boundary)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        let cuts = [start] + boundaries.sorted() + [end]
        var windows: [DateInterval] = []
        for index in 0..<(cuts.count - 1) {
            let interval = DateInterval(start: cuts[index], end: cuts[index + 1])
            if interval.duration >= 30 * 60 {
                windows.append(interval)
            }
        }
        return windows
    }
}
