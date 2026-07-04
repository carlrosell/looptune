import Foundation

/// A temporary schedule override (Nightscout `Temporary Override`).
///
/// Loop's semantics: during the period, scheduled basal is multiplied by
/// `insulinNeedsScaleFactor`, while ISF and CR are divided by it. An override
/// may only change the correction range (no scale factor). Indefinite overrides
/// have no fixed end until cancelled/superseded.
public struct OverridePeriod: Sendable, Equatable {
    public var startDate: Date
    /// `nil` for indefinite overrides (resolved against the next override/cancel
    /// during ingestion).
    public var endDate: Date?
    public var insulinNeedsScaleFactor: Double?
    /// Correction range in mg/dL, if the override changes it.
    public var correctionRangeMilligramsPerDeciliter: ClosedRange<Double>?
    public var reason: String?

    public init(
        startDate: Date,
        endDate: Date?,
        insulinNeedsScaleFactor: Double? = nil,
        correctionRangeMilligramsPerDeciliter: ClosedRange<Double>? = nil,
        reason: String? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.insulinNeedsScaleFactor = insulinNeedsScaleFactor
        self.correctionRangeMilligramsPerDeciliter = correctionRangeMilligramsPerDeciliter
        self.reason = reason
    }

    /// Whether this override alters insulin needs (and therefore perturbs
    /// basal/ISF/CR attribution during replay).
    public var affectsInsulinNeeds: Bool {
        if let factor = insulinNeedsScaleFactor { return abs(factor - 1.0) > 1e-9 }
        return false
    }

    /// Whether `date` falls within `[startDate, endDate)` (open-ended when
    /// `endDate` is nil).
    public func contains(_ date: Date) -> Bool {
        guard date >= startDate else { return false }
        if let endDate { return date < endDate }
        return true
    }
}
