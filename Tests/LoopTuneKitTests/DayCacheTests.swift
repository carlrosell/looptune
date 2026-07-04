import Testing
import Foundation
@testable import LoopTuneKit

@Suite("DayCache")
struct DayCacheTests {
    private func makeTempCache(maxAgeDays: Int = 30) -> DayCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("looptune-cache-tests-\(UUID().uuidString)", isDirectory: true)
        return DayCache(directory: dir, maxAgeDays: maxAgeDays)
    }

    @Test("NSEntry round-trips through wire-format encoding")
    func entryRoundTrip() throws {
        let entry = try JSONDecoder().decode(NSEntry.self, from: Data(#"{"date":1700000000000,"sgv":120,"type":"sgv","device":"share2"}"#.utf8))
        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(NSEntry.self, from: encoded)
        #expect(decoded == entry)
    }

    @Test("NSTreatment round-trips through wire-format encoding")
    func treatmentRoundTrip() throws {
        let json = #"{"eventType":"Temp Basal","created_at":"2023-01-09T20:44:28Z","rate":1.75,"amount":0.875,"duration":30.0,"temp":"absolute","automatic":true}"#
        let treatment = try JSONDecoder().decode(NSTreatment.self, from: Data(json.utf8))
        let encoded = try JSONEncoder().encode(treatment)
        let decoded = try JSONDecoder().decode(NSTreatment.self, from: encoded)
        #expect(decoded == treatment)
    }

    @Test("store and load a cached day")
    func storeAndLoad() throws {
        let cache = makeTempCache()
        let entry = try JSONDecoder().decode(NSEntry.self, from: Data(#"{"date":1700000000000,"sgv":120}"#.utf8))
        let day = CachedDay(day: "2023-11-14", fetchedAt: Date(), entries: [entry], treatments: [])
        cache.store(day, host: "my-site.example.com")

        let loaded = cache.load(host: "my-site.example.com", dayKey: "2023-11-14")
        #expect(loaded?.entries == [entry])
        #expect(loaded?.treatments.isEmpty == true)
        // Different host or day misses.
        #expect(cache.load(host: "other.example.com", dayKey: "2023-11-14") == nil)
        #expect(cache.load(host: "my-site.example.com", dayKey: "2023-11-15") == nil)
    }

    @Test("prune deletes days older than maxAgeDays and keeps recent ones")
    func pruning() {
        let cache = makeTempCache(maxAgeDays: 30)
        let now = Date()
        let recentKey = DayCache.dayKey(for: DayCache.floorToUTCDay(now.addingTimeInterval(-5 * 86_400)))
        let oldKey = DayCache.dayKey(for: DayCache.floorToUTCDay(now.addingTimeInterval(-40 * 86_400)))
        cache.store(CachedDay(day: recentKey, fetchedAt: now, entries: [], treatments: []), host: "site")
        cache.store(CachedDay(day: oldKey, fetchedAt: now, entries: [], treatments: []), host: "site")

        cache.pruneExpired(now: now)

        #expect(cache.load(host: "site", dayKey: recentKey) != nil)
        #expect(cache.load(host: "site", dayKey: oldKey) == nil)
    }

    @Test("shouldStore requires the day to be over for the freshness margin")
    func freshness() {
        let cache = makeTempCache()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Ended 25h ago: cacheable. Ended 2h ago: not yet.
        #expect(cache.shouldStore(dayEnd: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(!cache.shouldStore(dayEnd: now.addingTimeInterval(-2 * 3600), now: now))
    }

    @Test("UTC day buckets tile the window contiguously with stable keys")
    func buckets() {
        // 2023-11-14 12:00 UTC to 2023-11-16 06:00 UTC → 3 buckets (14th–16th).
        let start = Date(timeIntervalSince1970: 1_699_963_200)
        let end = Date(timeIntervalSince1970: 1_700_114_400)
        let buckets = DayCache.utcDayBuckets(covering: start, to: end)
        #expect(buckets.count == 3)
        #expect(buckets[0].key == "2023-11-14")
        #expect(buckets[2].key == "2023-11-16")
        for index in 1..<buckets.count {
            #expect(buckets[index].interval.start == buckets[index - 1].interval.end)
        }
        // Each bucket is exactly one UTC day.
        #expect(buckets.allSatisfy { $0.interval.duration == 86_400 })
    }

    @Test("corrupt cache files are dropped and treated as misses")
    func corruptFile() throws {
        let cache = makeTempCache()
        let url = cache.fileURL(host: "site", dayKey: "2023-11-14")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(cache.load(host: "site", dayKey: "2023-11-14") == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("host names are sanitized for the filesystem")
    func sanitize() {
        #expect(DayCache.sanitize("My-Site.Example.com") == "my-site.example.com")
        #expect(DayCache.sanitize("host:1337/path") == "host_1337_path")
    }
}

/// Routes stubbed responses by path and counts data requests.
final class RoutingStubTransport: NightscoutTransport, @unchecked Sendable {
    private(set) var dataRequestCount = 0

    private static let profileJSON = #"""
    [{"defaultProfile":"Default","units":"mg/dL","store":{"Default":{
      "timezone":"UTC",
      "basal":[{"timeAsSeconds":0,"value":1.0}],
      "sens":[{"timeAsSeconds":0,"value":50}],
      "carbratio":[{"timeAsSeconds":0,"value":10}],
      "target_low":[{"timeAsSeconds":0,"value":100}],
      "target_high":[{"timeAsSeconds":0,"value":110}]
    }}}]
    """#

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let body: String
        if path.contains("profile") {
            body = Self.profileJSON
        } else {
            dataRequestCount += 1
            body = "[]"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

@Suite("Pipeline day caching")
struct PipelineCachingTests {
    @Test("second run serves finished days from cache without network calls")
    func cacheHitOnSecondRun() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("looptune-pipeline-cache-\(UUID().uuidString)", isDirectory: true)
        let cache = DayCache(directory: dir)
        // A window ending 5 days ago: every bucket is finished (cacheable) yet
        // young enough to survive the 30-day prune.
        let end = Date().addingTimeInterval(-5 * 86_400)
        let config = TuningConfiguration(days: 2)

        let firstTransport = RoutingStubTransport()
        let firstClient = try NightscoutClient(rawURLString: "https://site.example.com", transport: firstTransport)
        _ = try await TuningPipeline().fetchInputs(client: firstClient, configuration: config, endingAt: end, cache: cache)
        #expect(firstTransport.dataRequestCount > 0)

        let secondTransport = RoutingStubTransport()
        let secondClient = try NightscoutClient(rawURLString: "https://site.example.com", transport: secondTransport)
        _ = try await TuningPipeline().fetchInputs(client: secondClient, configuration: config, endingAt: end, cache: cache)
        #expect(secondTransport.dataRequestCount == 0)
    }

    @Test("without a cache every run fetches from the network")
    func noCacheAlwaysFetches() async throws {
        let end = Date(timeIntervalSince1970: 1_700_000_000)
        let config = TuningConfiguration(days: 1)
        let transport = RoutingStubTransport()
        let client = try NightscoutClient(rawURLString: "https://site.example.com", transport: transport)
        _ = try await TuningPipeline().fetchInputs(client: client, configuration: config, endingAt: end, cache: nil)
        let first = transport.dataRequestCount
        _ = try await TuningPipeline().fetchInputs(client: client, configuration: config, endingAt: end, cache: nil)
        #expect(transport.dataRequestCount == first * 2)
    }

    @Test("boundary duplicates are dropped before ingestion")
    func boundaryDedupe() throws {
        let json = #"{"eventType":"Correction Bolus","created_at":"2023-11-15T00:00:00Z","insulin":2.0}"#
        let treatment = try JSONDecoder().decode(NSTreatment.self, from: Data(json.utf8))
        // The same document returned by two adjacent inclusive range queries.
        let deduped = TuningPipeline.dedupeAcrossBuckets([treatment, treatment])
        #expect(deduped.count == 1)
    }
}
