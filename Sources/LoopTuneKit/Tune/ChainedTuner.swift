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
        var mergedCategoryCounts: [DeviationCategory: Int] = [:]
        var totalSamples = 0
        var daysTuned = 0
        var dailyISF: [Double] = []
        var dailyCR: [Double] = []
        var lastOutput: TuningOutput?
        let tuner = LoopTuner(caps: caps, options: options)
        let replay = ReplayEngine()

        for window in windows {
            // If the user actually changed therapy settings by this window,
            // the applied settings supersede the simulated tuning trajectory:
            // restart the iteration from what is really running in Loop.
            if let history = inputs.profileHistory {
                let nowActive = history.activeProfile(at: window.start)
                if !nowActive.hasSameTherapySettings(as: activeHistorical) {
                    evolving = nowActive
                    activeHistorical = nowActive
                    settingsChanges.append(nowActive.activeFrom ?? window.start)
                }
            }

            // Trim to the inputs that can influence this window: replaying a
            // day with the full multi-day dataset is O(window) per day, which
            // makes the whole chained run quadratic.
            let trimmed = ReplayEngine.trimmedInputs(
                glucose: inputs.glucose,
                doses: inputs.doses,
                carbs: inputs.carbs,
                analysisStart: window.start,
                analysisEnd: window.end
            )
            // A window whose trimmed data is too sparse (or empty) counts as a
            // missing day rather than aborting the run.
            let deviations = (try? replay.computeDeviations(
                glucose: trimmed.glucose,
                doses: trimmed.doses,
                carbs: trimmed.carbs,
                profile: evolving,
                analysisStart: window.start,
                analysisEnd: window.end
            )) ?? []
            guard deviations.count >= Self.minimumSamplesPerDay else {
                // A whole day without usable data: every hour goes untuned.
                for hour in 0..<24 { daysMissing[hour] += 1 }
                continue
            }

            let output = tuner.tune(
                deviations: deviations,
                carbs: inputs.carbs,
                currentProfile: evolving,
                pumpProfile: pumpProfile,
                analysisStart: window.start,
                analysisEnd: window.end
            )

            for hour in 0..<24 {
                if output.untunedBasalHours[hour] { daysMissing[hour] += 1 }
                sampleCountByHour[hour] += output.basalSampleCountByHour[hour]
            }
            for (category, count) in output.categoryCounts {
                mergedCategoryCounts[category, default: 0] += count
            }
            totalSamples += output.totalSamples
            daysTuned += 1
            dailyISF.append(output.tunedISF)
            dailyCR.append(output.tunedCarbRatio)
            lastOutput = output

            evolving = try evolving.replacing(
                basalHourly: output.tunedBasalHourly,
                isf: output.tunedISF,
                carbRatio: output.tunedCarbRatio
            )
        }

        let totalWindows = windows.count
        guard var final = lastOutput else {
            // No tunable day at all: recommend the pump settings unchanged.
            let pumpHourly = pumpProfile.basalSchedule.hourlyValues()
            let pumpISF = pumpProfile.sensitivitySchedule.timeWeightedAverage()
            let pumpCR = pumpProfile.carbRatioSchedule.timeWeightedAverage()
            let output = TuningOutput(
                tunedBasalHourly: pumpHourly,
                pumpBasalHourly: pumpHourly,
                untunedBasalHours: Array(repeating: true, count: 24),
                tunedISF: pumpISF,
                pumpISF: pumpISF,
                tunedCarbRatio: pumpCR,
                pumpCarbRatio: pumpCR,
                categoryCounts: [:],
                totalSamples: 0
            )
            return ChainedTuningResult(
                output: output,
                daysMissingByHour: daysMissing,
                daysTuned: 0,
                dailyISF: [],
                dailyCarbRatio: [],
                settingsChanges: settingsChanges
            )
        }

        // Present accumulated coverage on the final output. An hour counts as
        // untuned overall only if it was missing on every window.
        final.categoryCounts = mergedCategoryCounts
        final.totalSamples = totalSamples
        final.basalSampleCountByHour = sampleCountByHour
        final.untunedBasalHours = daysMissing.map { $0 >= totalWindows }

        return ChainedTuningResult(
            output: final,
            daysMissingByHour: daysMissing,
            daysTuned: daysTuned,
            dailyISF: dailyISF,
            dailyCarbRatio: dailyCR,
            settingsChanges: settingsChanges
        )
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
