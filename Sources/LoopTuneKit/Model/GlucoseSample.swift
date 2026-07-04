import Foundation
import LoopAlgorithm

/// A single CGM reading. Stored internally in mg/dL (Nightscout `sgv` values are
/// always mg/dL regardless of the site's display units).
public struct GlucoseSample: Sendable, Equatable {
    public var date: Date
    /// Blood glucose in mg/dL.
    public var milligramsPerDeciliter: Double
    /// Source device string; used as the LoopAlgorithm provenance identifier.
    public var provenance: String

    public init(date: Date, milligramsPerDeciliter: Double, provenance: String = FixtureGlucoseSample.defaultProvenanceIdentifier) {
        self.date = date
        self.milligramsPerDeciliter = milligramsPerDeciliter
        self.provenance = provenance
    }

    /// Sensor error codes (`sgv < 39`) are dropped upstream, matching oref0.
    public static let minimumValidValue: Double = 39

    /// Adapt to the LoopAlgorithm sample type.
    ///
    /// - Parameter unifyProvenance: when `true`, use a constant provenance for
    ///   every sample. LoopAlgorithm's insulin-counteraction and momentum
    ///   computations silently drop intervals whose consecutive samples have
    ///   differing provenance, so replay uses a single provenance.
    public func fixture(unifyProvenance: Bool = true) -> FixtureGlucoseSample {
        FixtureGlucoseSample(
            provenanceIdentifier: unifyProvenance ? FixtureGlucoseSample.defaultProvenanceIdentifier : provenance,
            startDate: date,
            quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: milligramsPerDeciliter)
        )
    }
}
