import Foundation
import LoopAlgorithm

/// A unit of insulin delivery reconstructed from Nightscout treatments.
///
/// LoopAlgorithm consumes **absolute** delivery volumes (total units over the
/// interval) and nets temp basals against the scheduled basal internally, so a
/// temp basal is stored here by its effective delivered rate and converted to a
/// volume, and a suspend is a zero-volume basal dose.
public struct DoseRecord: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A bolus of `units` total units.
        case bolus(units: Double)
        /// A temp basal delivering `unitsPerHour` (the *effective* rate — from
        /// Nightscout's `amount / duration`, falling back to the programmed
        /// `rate`).
        case tempBasal(unitsPerHour: Double)
        /// A pump suspend: zero delivery over the interval.
        case suspend
    }

    public var kind: Kind
    public var startDate: Date
    public var endDate: Date
    /// Whether Loop enacted this automatically (autobolus / closed-loop temp).
    public var automatic: Bool
    public var insulinType: InsulinType?

    public init(kind: Kind, startDate: Date, endDate: Date, automatic: Bool = false, insulinType: InsulinType? = nil) {
        self.kind = kind
        self.startDate = startDate
        self.endDate = endDate
        self.automatic = automatic
        self.insulinType = insulinType
    }

    /// Total units delivered over the interval.
    public var deliveredUnits: Double {
        switch kind {
        case .bolus(let units):
            return units
        case .tempBasal(let unitsPerHour):
            return unitsPerHour * (endDate.timeIntervalSince(startDate) / 3600)
        case .suspend:
            return 0
        }
    }

    /// Adapt to the LoopAlgorithm dose type with an absolute volume.
    public func fixture(defaultInsulinType: InsulinType?) -> FixtureInsulinDose {
        let type = (insulinType ?? defaultInsulinType)?.fixtureType
        switch kind {
        case .bolus(let units):
            return FixtureInsulinDose(deliveryType: .bolus, startDate: startDate, endDate: endDate, volume: units, insulinType: type)
        case .tempBasal:
            return FixtureInsulinDose(deliveryType: .basal, startDate: startDate, endDate: endDate, volume: deliveredUnits, insulinType: type)
        case .suspend:
            return FixtureInsulinDose(deliveryType: .basal, startDate: startDate, endDate: endDate, volume: 0, insulinType: type)
        }
    }
}
