import Foundation

/// An analysis interval inside one recorded therapy settings period.
struct ReplaySegment: Sendable, Equatable {
    var interval: DateInterval
    /// The recorded profile in force throughout `interval`.
    var recorded: TherapyProfile
    /// When `recorded`'s therapy settings took effect, or nil when no earlier
    /// settings are known.
    var settingsActivation: Date?
}

/// The result of replaying one segment.
struct SegmentReplay: Sendable {
    /// Every replayed sample, including those inside insulin-needs overrides.
    var deviations: [DeviationSample]
    /// Samples outside insulin-needs overrides.
    var eligibleDeviations: [DeviationSample]
    /// The carbohydrate entries retained for the segment's replay; earlier
    /// meals among them can still explain its residuals.
    var retainedCarbs: [CarbRecord]
}

/// The historical replay context shared by chained tuning and diagnostics
/// (ADR 0004). It owns the day windows, the split at therapy activations, input
/// retention, the settings timeline, and override filtering, so the two
/// callers differ only in the candidate profile they replay for a segment.
struct HistoricalReplay: Sendable {
    let inputs: TuningInputs

    /// The analysis window as 04:00-local day windows, each split at the
    /// activations that change replay-relevant therapy.
    func segmentsByDay() -> [[ReplaySegment]] {
        Self.dayWindows(
            from: inputs.analysisStart,
            to: inputs.analysisEnd,
            timeZone: inputs.profile.timeZone
        ).map { window in
            Self.profileSegments(for: window, history: inputs.profileHistory).map {
                ReplaySegment(
                    interval: $0,
                    recorded: recordedProfile(at: $0.start),
                    settingsActivation: settingsActivation(at: $0.start)
                )
            }
        }
    }

    /// The profile recorded as active at `date`, or the input profile without
    /// history.
    func recordedProfile(at date: Date) -> TherapyProfile {
        inputs.profileHistory?.activeProfile(at: date) ?? inputs.profile
    }

    /// The start of the uninterrupted run of recorded profiles that share the
    /// therapy settings active at `date`. Uploads that only change targets or
    /// limits do not start a new settings period.
    func settingsActivation(at date: Date) -> Date? {
        guard let history = inputs.profileHistory else { return nil }
        let active = history.activeProfile(at: date)
        var activation: Date?
        for profile in history.timeline.reversed() {
            guard let activeFrom = profile.activeFrom, activeFrom <= date else { continue }
            guard profile.hasSameTherapySettings(as: active) else { break }
            activation = activeFrom
        }
        return activation
    }

    /// Replay `segment` with `candidate` standing in for its recorded settings
    /// from the segment's activation onward. Inputs that began before the
    /// activation keep the settings recorded for their start.
    func replay(_ segment: ReplaySegment, candidate: TherapyProfile) throws -> SegmentReplay {
        // Trim to the inputs that can influence this segment: replaying with
        // the full multi-day dataset would make chaining quadratic.
        let retained = ReplayEngine.trimmedInputs(
            glucose: inputs.glucose,
            doses: inputs.doses,
            carbs: inputs.carbs,
            analysisStart: segment.interval.start,
            analysisEnd: segment.interval.end
        )
        let settings = TherapyTimeline(
            history: inputs.profileHistory,
            candidate: candidate,
            from: segment.settingsActivation
        )
        let deviations: [DeviationSample]
        do {
            deviations = try ReplayEngine().computeDeviations(
                glucose: retained.glucose,
                doses: retained.doses,
                carbs: retained.carbs,
                settings: settings,
                analysisStart: segment.interval.start,
                analysisEnd: segment.interval.end
            )
        } catch ReplayEngine.ReplayError.insufficientGlucose {
            deviations = []
        }
        return SegmentReplay(
            deviations: deviations,
            eligibleDeviations: inputs.eligibleDeviations(deviations),
            retainedCarbs: retained.carbs
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
            if let boundary = calendar.date(
                bySettingHour: ChainedTuner.dayBoundaryHour,
                minute: 0,
                second: 0,
                of: day
            ), boundary > start, boundary < end {
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
