import Foundation
import LoopAlgorithm

/// The therapy settings replay applies at each instant of its input window.
///
/// LoopAlgorithm reads the insulin sensitivity and carb ratio in force when
/// each dose or meal began, and nets temp basals against the basal scheduled
/// at each instant. A single profile expanded over the whole lookback would
/// reinterpret inputs from before a settings change with the newer values.
/// A timeline instead keeps a sequence of settings periods: recorded history
/// up to the activation of the period under analysis, then the candidate
/// profile for that period (ADR 0004).
public struct TherapyTimeline: Sendable {
    struct Period: Sendable {
        /// When this period's settings took effect; the first period also
        /// covers everything before it.
        var start: Date
        var profile: TherapyProfile
    }

    /// Ascending by `start`. Never empty.
    let periods: [Period]

    /// One profile in force at every instant.
    public init(profile: TherapyProfile) {
        periods = [Period(start: .distantPast, profile: profile)]
    }

    /// Recorded history before `activation`, then `candidate` from it onward.
    ///
    /// `candidate` stands in for the settings period that began at
    /// `activation`: the recorded settings themselves, a chained tuning
    /// hypothesis, or a recommendation. Inputs that began before `activation`
    /// keep the settings recorded for their start. Without history or an
    /// activation date the candidate applies throughout. Before the earliest
    /// recorded activation, the earliest recorded profile applies, matching
    /// `ProfileHistory.activeProfile(at:)`. Recorded uploads that keep the
    /// previous therapy settings, such as target-only changes, do not start a
    /// new period.
    public init(history: ProfileHistory?, candidate: TherapyProfile, from activation: Date?) {
        var periods: [Period] = []
        if let history, let activation {
            for profile in history.timeline {
                guard let activeFrom = profile.activeFrom, activeFrom < activation else { continue }
                if let last = periods.last, last.profile.hasSameTherapySettings(as: profile) { continue }
                periods.append(Period(start: periods.isEmpty ? .distantPast : activeFrom, profile: profile))
            }
        }
        periods.append(Period(start: periods.isEmpty ? .distantPast : activation ?? .distantPast, profile: candidate))
        self.periods = periods
    }

    /// The settings in force at `date`.
    public func profile(at date: Date) -> TherapyProfile {
        var result = periods[0].profile
        for period in periods.dropFirst() where period.start <= date {
            result = period.profile
        }
        return result
    }

    /// Scheduled basal (U/hr) tiling `[start, end]`.
    public func basalTimeline(from start: Date, to end: Date) -> [AbsoluteScheduleValue<Double>] {
        timeline(from: start, to: end) { $0.basalTimeline(from: $1, to: $2) }
    }

    /// ISF (mg/dL/U) tiling `[start, end]`.
    public func sensitivityTimeline(from start: Date, to end: Date) -> [AbsoluteScheduleValue<LoopQuantity>] {
        timeline(from: start, to: end) { $0.sensitivityTimeline(from: $1, to: $2) }
    }

    /// Carb ratio (g/U) tiling `[start, end]`.
    public func carbRatioTimeline(from start: Date, to end: Date) -> [AbsoluteScheduleValue<Double>] {
        timeline(from: start, to: end) { $0.carbRatioTimeline(from: $1, to: $2) }
    }

    /// Expand each period's schedule over its share of `[start, end]` and
    /// concatenate. Every period boundary stays a cut, even where a schedule
    /// has the same value on both sides: LoopAlgorithm splits temp basals only
    /// at basal timeline boundaries and models each part with the ISF in force
    /// at its start, so merging equal basal values would model insulin
    /// delivered after an ISF-only change with the earlier ISF. A single
    /// period yields exactly the profile's own expansion.
    private func timeline<Value>(
        from start: Date,
        to end: Date,
        expand: (TherapyProfile, Date, Date) -> [AbsoluteScheduleValue<Value>]
    ) -> [AbsoluteScheduleValue<Value>] {
        var result: [AbsoluteScheduleValue<Value>] = []
        for index in periods.indices {
            let periodEnd = index + 1 < periods.count ? periods[index + 1].start : .distantFuture
            let lower = max(start, periods[index].start)
            let upper = min(end, periodEnd)
            guard lower < upper else { continue }
            result += expand(periods[index].profile, lower, upper)
        }
        return result
    }
}
