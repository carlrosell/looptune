import Foundation

/// A start-time + rate pair exactly as entered on Loop's Basal Rates screen,
/// which lists only the change points of the schedule (e.g. `06:00 — 0.25`).
public struct LoopBasalEntry: Sendable, Equatable, Identifiable {
    /// Stable identity for table presentation: the start offset.
    public var id: Int { startMinutes }

    /// Minutes since local midnight.
    public var startMinutes: Int
    /// U/hr, already rounded to the pump increment. For hours with
    /// insufficient data, the pump rate.
    public var rate: Double
    /// Set when the hours in this entry had insufficient data (ADR 0011). The
    /// alternative is the interpolated rate rounded to the pump increment.
    public var insufficientEvidence: InsufficientEvidence<Double>?

    public init(startMinutes: Int, rate: Double, insufficientEvidence: InsufficientEvidence<Double>? = nil) {
        self.startMinutes = startMinutes
        self.rate = rate
        self.insufficientEvidence = insufficientEvidence
    }

    public var evidenceStatus: BlockEvidenceStatus {
        insufficientEvidence == nil ? .tuned : .insufficientData
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
    ///
    /// Hours with insufficient data keep the pump rate and carry the rounded
    /// interpolated alternative. They collapse only with neighbours offering
    /// the same values from the same sources, never with tuned hours.
    func loopBasalSchedule(increment: Double = BasalHourRecommendation.loopBasalIncrement) -> [LoopBasalEntry] {
        var entries: [LoopBasalEntry] = []
        for hour in basalHours.sorted(by: { $0.hour < $1.hour }) {
            let entry = LoopBasalEntry(
                startMinutes: hour.hour * 60,
                rate: hour.roundedRate(toIncrement: increment),
                insufficientEvidence: hour.insufficientEvidence.map {
                    InsufficientEvidence(
                        interpolated: hour.interpolatedRoundedRate(toIncrement: increment),
                        sources: $0.sources
                    )
                }
            )
            if let last = entries.last,
               last.rate == entry.rate,
               last.insufficientEvidence == entry.insufficientEvidence {
                continue
            }
            entries.append(entry)
        }
        return entries
    }
}
