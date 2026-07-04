import Foundation

/// A start-time + rate pair exactly as entered on Loop's Basal Rates screen,
/// which lists only the change points of the schedule (e.g. `06:00 — 0.25`).
public struct LoopBasalEntry: Sendable, Equatable, Identifiable {
    /// Stable identity for table presentation: the start offset.
    public var id: Int { startMinutes }

    /// Minutes since local midnight.
    public var startMinutes: Int
    /// U/hr, already rounded to the pump increment.
    public var rate: Double

    public init(startMinutes: Int, rate: Double) {
        self.startMinutes = startMinutes
        self.rate = rate
    }

    /// `HH:mm` as shown in Loop.
    public var timeString: String {
        String(format: "%02d:%02d", startMinutes / 60, startMinutes % 60)
    }
}

public extension TuningRecommendation {
    /// The recommended basal schedule as Loop schedule entries: pump-increment
    /// rounded rates with adjacent equal values collapsed, so each row is one
    /// line to enter on Loop's Basal Rates screen. Always starts at 00:00.
    func loopBasalSchedule(increment: Double = BasalHourRecommendation.loopBasalIncrement) -> [LoopBasalEntry] {
        var entries: [LoopBasalEntry] = []
        for hour in basalHours.sorted(by: { $0.hour < $1.hour }) {
            let rate = hour.roundedRate(toIncrement: increment)
            if let last = entries.last, last.rate == rate { continue }
            entries.append(LoopBasalEntry(startMinutes: hour.hour * 60, rate: rate))
        }
        return entries
    }
}
