import Foundation
import Testing
@testable import LoopTuneKit

@Suite("Saved run source")
struct SavedRunSourceTests {
    private func origin(_ string: String) throws -> SiteOrigin {
        try #require(URL(string: string).flatMap(SiteOrigin.init(url:)))
    }

    private func makeRun(origin: SiteOrigin? = nil, siteHost: String = "site") throws -> SavedRun {
        let output = TuningOutput(
            tunedBasalHourly: Array(repeating: 1.0, count: 24),
            pumpBasalHourly: Array(repeating: 1.0, count: 24),
            untunedBasalHours: Array(repeating: false, count: 24),
            tunedISF: 50, pumpISF: 50, tunedCarbRatio: 10, pumpCarbRatio: 10,
            categoryCounts: [:], totalSamples: 10
        )
        let recommendation = try TuningRecommendation(from: output, daysAnalyzed: 1)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let diagnostics = RunDiagnostics(
            glucoseCount: 288, doseCount: 5, carbCount: 2, windowStart: date, windowEnd: date,
            daySummaries: [], hourlyDeviation: [], meanAbsDeviationBefore: 4, meanAbsDeviationAfter: 3
        )
        let id = RunStore.makeID(createdAt: date)
        if let origin {
            return SavedRun(id: id, createdAt: date, origin: origin, days: 1, insulinType: .novolog,
                            recommendation: recommendation, diagnostics: diagnostics)
        }
        return SavedRun(id: id, createdAt: date, siteHost: siteHost, days: 1, insulinType: .novolog,
                        recommendation: recommendation, diagnostics: diagnostics)
    }

    /// Encode `run`, apply `edit` to its JSON object, and decode the result.
    private func roundTrip(_ run: SavedRun, edit: (inout [String: Any]) -> Void = { _ in }) throws -> SavedRun {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any]
        )
        edit(&object)
        return try JSONDecoder().decode(SavedRun.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("a new run stores its canonical origin and the legacy host")
    func newRecordRoundTrip() throws {
        let run = try makeRun(origin: origin("HTTP://LocalHost:1337/api/v1"))
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any]
        )
        #expect(object["siteOrigin"] as? String == "http://localhost:1337")
        #expect(object["siteHost"] as? String == "localhost")

        let decoded = try roundTrip(run)
        #expect(decoded == run)
        #expect(decoded.source == .origin(try origin("http://localhost:1337")))
        #expect(decoded.source.label == "http://localhost:1337")
    }

    @Test("a host-only legacy record loads without an assumed scheme or port")
    func legacyRecord() throws {
        let decoded = try roundTrip(makeRun(origin: origin("http://localhost:8080"))) { object in
            object.removeValue(forKey: "siteOrigin")
        }
        #expect(decoded.siteOrigin == nil)
        #expect(decoded.origin == nil)
        #expect(decoded.siteHost == "localhost")
        #expect(decoded.source == .host("localhost"))
        #expect(decoded.source.label == "localhost")

        #expect(try makeRun(siteHost: "Site.Example.com").source.label == "site.example.com")
        #expect(try makeRun(siteHost: "::1").source.label == "[::1]")
    }

    @Test("origins on one host with different ports stay distinct")
    func portsStayDistinct() throws {
        let a = try roundTrip(makeRun(origin: origin("http://localhost:1337")))
        let b = try roundTrip(makeRun(origin: origin("http://localhost:8080")))
        #expect(a.siteHost == b.siteHost)
        #expect(a.source != b.source)
        #expect(a.source.label == "http://localhost:1337")
        #expect(b.source.label == "http://localhost:8080")
        #expect(try makeRun(origin: origin("https://example.com:443")).source.label == "https://example.com")
    }

    @Test("labels never contain user information, path, query, or token")
    func labelsOmitCredentials() throws {
        let secrets = ["user", "hunter2", "api", "token", "abc123", "frag"]
        let fromURL = try makeRun(
            origin: origin("https://user:hunter2@site.example.com:8443/api/v1?token=abc123#frag")
        )
        #expect(fromURL.source.label == "https://site.example.com:8443")

        // An edited file cannot put credentials into the label either.
        let editedOrigin = try roundTrip(fromURL) { object in
            object["siteOrigin"] = "https://user:hunter2@site.example.com:8443/api?token=abc123#frag"
        }
        #expect(editedOrigin.source.label == "https://site.example.com:8443")
        let editedHost = try roundTrip(makeRun()) { object in
            object["siteHost"] = "user:hunter2@site.example.com/api?token=abc123"
        }
        #expect(editedHost.source == .unknown)

        for run in [fromURL, editedOrigin, editedHost] {
            for secret in secrets {
                #expect(!run.source.label.contains(secret))
            }
        }
    }
}
