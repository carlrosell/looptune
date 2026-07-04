import Foundation

/// A completed analysis, persisted so it can be revisited later. Bundles the
/// recommendation, the detail/diagnostics, and enough metadata to list it.
public struct SavedRun: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var createdAt: Date
    public var siteHost: String
    public var days: Int
    public var insulinTypeRaw: String
    public var recommendation: TuningRecommendation
    public var diagnostics: RunDiagnostics

    public init(
        id: String,
        createdAt: Date,
        siteHost: String,
        days: Int,
        insulinType: InsulinType,
        recommendation: TuningRecommendation,
        diagnostics: RunDiagnostics
    ) {
        self.id = id
        self.createdAt = createdAt
        self.siteHost = siteHost
        self.days = days
        self.insulinTypeRaw = insulinType.rawValue
        self.recommendation = recommendation
        self.diagnostics = diagnostics
    }

    public var insulinType: InsulinType {
        InsulinType(rawValue: insulinTypeRaw) ?? .novolog
    }

    /// A one-line summary of the headline changes, e.g. "ISF +6% · CR −4%".
    public var headline: String {
        let basal = percent(recommendation.pumpDailyBasal, recommendation.tunedDailyBasal)
        return "Basal \(basal) · ISF \(signed(recommendation.sensitivity.percentChange)) · CR \(signed(recommendation.carbRatio.percentChange))"
    }

    private func percent(_ from: Double, _ to: Double) -> String {
        guard from > 0 else { return "±0%" }
        return signed((to - from) / from * 100)
    }

    private func signed(_ value: Double) -> String {
        String(format: "%+.0f%%", value)
    }
}
