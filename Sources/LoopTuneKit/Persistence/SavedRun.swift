import Foundation

/// A completed analysis, persisted so it can be revisited later. Bundles the
/// recommendation, the detail/diagnostics, and enough metadata to list it.
///
/// The analyzed site is recorded as `siteOrigin`, the canonical
/// `SiteOrigin.description` (ADR 0003), such as `http://localhost:1337`.
/// Records written before origins were saved have only `siteHost`, which
/// lacks the scheme and port; new records still write it so older versions
/// can read them.
public struct SavedRun: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var createdAt: Date
    public var siteHost: String
    /// The canonical origin string, or `nil` for a host-only legacy record.
    public var siteOrigin: String?
    public var days: Int
    public var insulinTypeRaw: String
    public var recommendation: TuningRecommendation
    public var diagnostics: RunDiagnostics

    public init(
        id: String,
        createdAt: Date,
        origin: SiteOrigin,
        days: Int,
        insulinType: InsulinType,
        recommendation: TuningRecommendation,
        diagnostics: RunDiagnostics
    ) {
        self.init(
            id: id,
            createdAt: createdAt,
            siteHost: origin.host,
            days: days,
            insulinType: insulinType,
            recommendation: recommendation,
            diagnostics: diagnostics
        )
        self.siteOrigin = origin.description
    }

    /// A record with only a hostname, as runs were saved before origins.
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

    /// The site this run analyzed, parsed again from `siteOrigin`. `nil` for
    /// a legacy record or a stored value that is not an origin.
    public var origin: SiteOrigin? {
        siteOrigin.flatMap { URL(string: $0) }.flatMap { SiteOrigin(url: $0) }
    }

    /// Where this run's data came from, for display. A recorded origin is
    /// shown in its canonical form, which never contains user information,
    /// path, query, or fragment. A legacy record shows its hostname only if
    /// it is a valid host by itself; no scheme or port is assumed for it.
    public var source: Source {
        if let origin { return .origin(origin) }
        let host = siteHost.lowercased()
        let unbracketed = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let literal = unbracketed.contains(":") ? "[\(unbracketed)]" : unbracketed
        if let parsed = URL(string: "https://\(literal)").flatMap({ SiteOrigin(url: $0) }),
           parsed.host == unbracketed,
           parsed.usesDefaultPort {
            return .host(parsed.host)
        }
        return .unknown
    }

    public enum Source: Equatable, Sendable {
        /// The scheme, host, and port the run fetched from.
        case origin(SiteOrigin)
        /// A legacy record's hostname; its scheme and port were not saved.
        case host(String)
        /// A legacy record without a usable hostname.
        case unknown

        /// A one-line label, for example `http://localhost:1337`.
        public var label: String {
            switch self {
            case let .origin(origin): return origin.description
            case let .host(host): return host.contains(":") ? "[\(host)]" : host
            case .unknown: return "Unknown site"
            }
        }
    }

    /// A one-line summary of the headline changes, e.g. "ISF +6% · CR −4%".
    public var headline: String {
        let basal = percent(recommendation.pumpDailyBasal, recommendation.roundedDailyBasal())
        return "Basal \(basal) · ISF \(signed(recommendation.sensitivity.percentChange)) · CR \(signed(recommendation.carbRatio.percentChange))"
    }

    private func percent(_ from: Double, _ to: Double) -> String {
        guard from > 0 else { return "±0%" }
        return signed((to - from) / from * 100)
    }

    private func signed(_ value: Double) -> String {
        abs(value) < 0.5 ? "0%" : String(format: "%+.0f%%", value)
    }
}
