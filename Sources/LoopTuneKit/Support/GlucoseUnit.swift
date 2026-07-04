import Foundation

/// Blood-glucose display unit. LoopTune stores every glucose value internally in
/// mg/dL (matching Nightscout `sgv` entries and the LoopAlgorithm package), and
/// uses this only for parsing profile values and for display.
public enum GlucoseUnit: String, Codable, Sendable, CaseIterable {
    case milligramsPerDeciliter
    case millimolesPerLiter

    /// Exact conversion factor used across Loop/oref0/Nightscout.
    public static let millimolesPerLiterToMilligramsPerDeciliter = 18.01559

    /// Interpret a Nightscout units string, which appears in many casings in the
    /// wild (`mg/dl`, `mg/dL`, `mmol`, `mmol/l`, `mmol/L`, and a non-breaking
    /// space variant of `mmol/L` from older Loop). Anything containing "mmol"
    /// (case-insensitive) is millimoles; everything else defaults to mg/dL.
    public init(nightscoutString raw: String?) {
        guard let raw else {
            self = .milligramsPerDeciliter
            return
        }
        let normalized = raw.lowercased().replacingOccurrences(of: "\u{00a0}", with: " ")
        self = normalized.contains("mmol") ? .millimolesPerLiter : .milligramsPerDeciliter
    }

    /// Convert a value expressed in this unit into mg/dL.
    public func toMilligramsPerDeciliter(_ value: Double) -> Double {
        switch self {
        case .milligramsPerDeciliter:
            return value
        case .millimolesPerLiter:
            return value * Self.millimolesPerLiterToMilligramsPerDeciliter
        }
    }

    /// Convert a value expressed in mg/dL into this unit.
    public func fromMilligramsPerDeciliter(_ value: Double) -> Double {
        switch self {
        case .milligramsPerDeciliter:
            return value
        case .millimolesPerLiter:
            return value / Self.millimolesPerLiterToMilligramsPerDeciliter
        }
    }
}
