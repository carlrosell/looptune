import Foundation
import LoopAlgorithm

/// The insulin brand a user is dosing with, which selects the exponential
/// insulin model Loop uses. Mirrors LoopAlgorithm's `FixtureInsulinType` but is
/// `Sendable`/`Hashable` so it can live in LoopTune's value types (the package
/// enum is not `Sendable`).
public enum InsulinType: String, Sendable, Codable, CaseIterable, Hashable {
    case novolog
    case humalog
    case apidra
    case fiasp
    case lyumjev
    case afrezza

    /// The LoopAlgorithm fixture type used when building algorithm inputs.
    public var fixtureType: FixtureInsulinType {
        switch self {
        case .novolog: return .novolog
        case .humalog: return .humalog
        case .apidra: return .apidra
        case .fiasp: return .fiasp
        case .lyumjev: return .lyumjev
        case .afrezza: return .afrezza
        }
    }

    /// The two families the reference tools expose (rapid vs ultra-rapid), used
    /// when a user picks a curve rather than a specific brand.
    public var isUltraRapid: Bool {
        switch self {
        case .fiasp, .lyumjev, .afrezza: return true
        case .novolog, .humalog, .apidra: return false
        }
    }
}
