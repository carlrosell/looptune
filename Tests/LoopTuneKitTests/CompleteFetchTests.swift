import Testing
import Foundation
@testable import LoopTuneKit

/// A synthetic Nightscout site that answers like the v1 API: range filters on
/// `find[date]` and `find[created_at]`, the newest `count` matches first, and
/// profile documents newest first by `startDate`.
final class CappedNightscoutTransport: NightscoutTransport, @unchecked Sendable {
    struct Request {
        let path: String
        let items: [String: String]
        var count: Int? { items["count"].flatMap(Int.init) }
    }

    var entries: [NSEntry] = []
    var treatments: [(date: Date, json: String)] = []
    var profiles: [(start: Date, basal: Double)] = []
    /// Answers every profile request with `count` documents, all newer than
    /// any requested boundary, like a history that never ends.
    var unboundedProfiles: Date?
    /// Ignore the range filters and always return the newest records.
    var ignoresRange = false
    private(set) var requests: [Request] = []

    func requests(to fragment: String) -> [Request] {
        requests.filter { $0.path.contains(fragment) }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        var items: [String: String] = [:]
        for item in components.queryItems ?? [] { items[item.name] = item.value }
        let recorded = Request(path: components.path, items: items)
        requests.append(recorded)
        let count = recorded.count ?? 10

        let body: String
        if recorded.path.contains("profile") {
            body = "[" + profileDocuments(count: count).joined(separator: ",") + "]"
        } else if recorded.path.contains("entries") {
            let low = items["find[date][$gte]"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
            let high = items["find[date][$lte]"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
            let matches = entries
                .filter { ignoresRange || ($0.date >= low! && $0.date <= high!) }
                .sorted { $0.date > $1.date }
                .prefix(count)
            body = String(data: try JSONEncoder().encode(Array(matches)), encoding: .utf8)!
        } else {
            let formatter = ISO8601DateFormatter()
            let low = items["find[created_at][$gte]"].flatMap(formatter.date(from:))
            let high = items["find[created_at][$lte]"].flatMap(formatter.date(from:))
            let matches = treatments
                .filter { ignoresRange || ($0.date >= low! && $0.date <= high!) }
                .sorted { $0.date > $1.date }
                .prefix(count)
            body = "[" + matches.map(\.json).joined(separator: ",") + "]"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    private func profileDocuments(count: Int) -> [String] {
        if let newest = unboundedProfiles {
            return (0..<count).map {
                Self.profileJSON(start: newest.addingTimeInterval(-Double($0)), basal: 1.0)
            }
        }
        return profiles
            .sorted { $0.start > $1.start }
            .prefix(count)
            .map { Self.profileJSON(start: $0.start, basal: $0.basal) }
    }

    static func profileJSON(start: Date, basal: Double) -> String {
        #"""
        {"defaultProfile":"Default","units":"mg/dL","startDate":"\#(NightscoutClient.iso(start))","store":{"Default":{
          "timezone":"UTC",
          "basal":[{"timeAsSeconds":0,"value":\#(basal)}],
          "sens":[{"timeAsSeconds":0,"value":50}],
          "carbratio":[{"timeAsSeconds":0,"value":10}],
          "target_low":[{"timeAsSeconds":0,"value":100}],
          "target_high":[{"timeAsSeconds":0,"value":110}]
        }}}
        """#
    }

    static func bolusJSON(id: String, at date: Date, units: Double = 0.05) -> String {
        #"{"_id":"\#(id)","eventType":"Correction Bolus","created_at":"\#(NightscoutClient.iso(date))","insulin":\#(units)}"#
    }
}

@Suite("Complete Nightscout fetches")
struct CompleteFetchTests {
    /// 2023-11-14T22:13:20Z. With one analysis day the buckets are
    /// 2023-11-12 through 2023-11-15.
    let end = Date(timeIntervalSince1970: 1_700_000_000)
    let configuration = TuningConfiguration(days: 1)
    var analysisStart: Date { end.addingTimeInterval(-86_400) }
    var earliestReplayInput: Date { analysisStart.addingTimeInterval(-ReplayEngine.inputLookback) }
    /// 2023-11-14T00:00:00Z, the start of a fetched UTC day bucket.
    let dayStart = Date(timeIntervalSince1970: 1_699_920_000)
    let pageSize = TuningPipeline.recordPageSize

    func makeClient(_ transport: CappedNightscoutTransport) throws -> NightscoutClient {
        try NightscoutClient(rawURLString: "https://site.example.com", transport: transport)
    }

    func makeTransport() -> CappedNightscoutTransport {
        let transport = CappedNightscoutTransport()
        transport.profiles = [(start: analysisStart.addingTimeInterval(-30 * 86_400), basal: 1.0)]
        return transport
    }

    func fetch(_ transport: CappedNightscoutTransport, cache: DayCache? = nil, endingAt end: Date? = nil) async throws -> TuningInputs {
        try await TuningPipeline().fetchInputs(
            client: makeClient(transport),
            configuration: configuration,
            endingAt: end ?? self.end,
            cache: cache
        )
    }

    func doses(count: Int, from start: Date, spacing: TimeInterval) -> [(date: Date, json: String)] {
        (0..<count).map { index in
            let date = start.addingTimeInterval(Double(index) * spacing)
            return (date, CappedNightscoutTransport.bolusJSON(id: "dose-\(index)", at: date))
        }
    }

    func basal(_ profile: TherapyProfile) -> Double {
        profile.basalSchedule.value(atSecondsSinceMidnight: 0)
    }

    // MARK: - Records

    @Test("all 1,501 doses in a saturated day reach the analysis")
    func saturatedTreatmentsAreComplete() async throws {
        let transport = makeTransport()
        transport.treatments = doses(count: pageSize + 1, from: dayStart.addingTimeInterval(60), spacing: 30)

        let inputs = try await fetch(transport)

        #expect(inputs.doses.count == pageSize + 1)
        #expect(Set(inputs.doses.map(\.startDate)).count == pageSize + 1)
        #expect(transport.requests(to: "treatments").allSatisfy { $0.count == pageSize })
    }

    @Test("all 1,501 readings in a saturated day reach the analysis")
    func saturatedEntriesAreComplete() async throws {
        let transport = makeTransport()
        transport.entries = (0..<(pageSize + 1)).map {
            NSEntry(date: dayStart.addingTimeInterval(60 + Double($0) * 30), sgv: 100, type: "sgv", device: nil)
        }

        let inputs = try await fetch(transport)

        #expect(inputs.glucose.count == pageSize + 1)
    }

    @Test("an exactly full day is split once and records on the shared midpoint are not doubled")
    func exactLimitWithMidpointDuplicates() async throws {
        let transport = makeTransport()
        let midpoint = dayStart.addingTimeInterval(43_200)
        // Three identified doses and one without an ID sit on the inclusive
        // boundary that both halves of the split query return.
        let onMidpoint = (0..<3).map {
            (date: midpoint, json: CappedNightscoutTransport.bolusJSON(id: "mid-\($0)", at: midpoint, units: 1 + Double($0)))
        } + [(date: midpoint, json: #"{"eventType":"Correction Bolus","created_at":"\#(NightscoutClient.iso(midpoint))","insulin":7}"#)]
        transport.treatments = onMidpoint + doses(count: pageSize - onMidpoint.count, from: dayStart.addingTimeInterval(60), spacing: 30)

        let inputs = try await fetch(transport)

        #expect(inputs.doses.count == pageSize)
        let dayQueries = transport.requests(to: "treatments").filter {
            $0.items["find[created_at][$gte]"] == NightscoutClient.iso(dayStart)
                || $0.items["find[created_at][$lte]"] == NightscoutClient.iso(dayStart.addingTimeInterval(86_400))
        }
        #expect(dayQueries.count == 3)
        #expect(dayQueries.filter { $0.items.values.contains(NightscoutClient.iso(midpoint)) }.count == 2)
    }

    @Test("a full range that cannot be split is rejected")
    func unsplittableRangeIsRejected() async throws {
        let transport = makeTransport()
        let instant = dayStart.addingTimeInterval(3600)
        transport.treatments = (0..<pageSize).map {
            (date: instant, json: CappedNightscoutTransport.bolusJSON(id: "same-\($0)", at: instant))
        }

        await #expect {
            _ = try await fetch(transport)
        } throws: { error in
            guard case let TuningPipeline.PipelineError.incompleteRecords(collection, start, end) = error else { return false }
            return collection == "treatments" && start <= instant && instant <= end
                && end.timeIntervalSince(start) < 2
        }
    }

    @Test("a server that ignores the range filter is rejected within the query budget")
    func nonProgressingServerIsRejected() async throws {
        let transport = makeTransport()
        transport.ignoresRange = true
        transport.entries = (0..<pageSize).map {
            NSEntry(date: dayStart.addingTimeInterval(Double($0) * 60), sgv: 100, type: "sgv", device: nil)
        }

        await #expect {
            _ = try await fetch(transport)
        } throws: { error in
            guard case let TuningPipeline.PipelineError.incompleteRecords(collection, _, _) = error else { return false }
            return collection == "entries"
        }
        #expect(transport.requests(to: "entries").count <= TuningPipeline.maximumQueriesPerDay)
        #expect(transport.requests(to: "treatments").isEmpty)
    }

    @Test("small responses keep one query per collection and day")
    func unsaturatedQueriesAreUnchanged() async throws {
        let transport = makeTransport()
        transport.entries = [NSEntry(date: dayStart.addingTimeInterval(60), sgv: 100, type: "sgv", device: nil)]
        transport.treatments = doses(count: 10, from: dayStart.addingTimeInterval(60), spacing: 300)

        let inputs = try await fetch(transport)

        let buckets = DayCache.utcDayBuckets(
            covering: analysisStart.addingTimeInterval(-86_400),
            to: end.addingTimeInterval(6 * 3600)
        )
        #expect(transport.requests(to: "profile").map(\.count) == [TuningPipeline.initialProfileCount])
        #expect(transport.requests(to: "entries").map { $0.items["find[date][$gte]"] }
            == buckets.map { NightscoutClient.epochMilliseconds($0.interval.start) })
        #expect(transport.requests(to: "treatments").map { $0.items["find[created_at][$lte]"] }
            == buckets.map { NightscoutClient.iso($0.interval.end) })
        #expect((transport.requests(to: "entries") + transport.requests(to: "treatments")).allSatisfy { $0.count == pageSize })
        #expect(inputs.glucose.count == 1)
        #expect(inputs.doses.count == 10)
    }

    // MARK: - Profile history

    @Test("the profile active before the earliest replay input is fetched")
    func missingProfileBaselineIsFetched() async throws {
        let transport = CappedNightscoutTransport()
        // The oldest of 101 documents covers the earliest replay input; the
        // newest 100 all start after it.
        transport.profiles = [(start: earliestReplayInput.addingTimeInterval(-86_400), basal: 0.5)]
            + (1...100).map { (start: earliestReplayInput.addingTimeInterval(Double($0) * 60), basal: 1.0) }

        let inputs = try await fetch(transport)

        let history = try #require(inputs.profileHistory)
        #expect(history.timeline.count == 101)
        #expect(basal(history.activeProfile(at: earliestReplayInput)) == 0.5)
        #expect(basal(history.activeProfile(at: earliestReplayInput.addingTimeInterval(60))) == 1.0)
        #expect(transport.requests(to: "profile").map(\.count) == [100, 200])
    }

    @Test("a full profile response that already covers the boundary is not extended")
    func coveredProfileHistoryNeedsOneRequest() async throws {
        let transport = CappedNightscoutTransport()
        transport.profiles = (0..<150).map {
            (start: earliestReplayInput.addingTimeInterval(Double(10 - $0) * 3600), basal: $0 == 10 ? 0.5 : 1.0)
        }

        let inputs = try await fetch(transport)

        #expect(transport.requests(to: "profile").map(\.count) == [100])
        #expect(basal(try #require(inputs.profileHistory).activeProfile(at: earliestReplayInput)) == 0.5)
    }

    @Test("a document tied with the oldest returned start date does not prove coverage")
    func tiedOldestProfileIsExtended() async throws {
        let transport = CappedNightscoutTransport()
        let tied = earliestReplayInput.addingTimeInterval(-3600)
        transport.profiles = [(start: tied, basal: 0.5), (start: tied, basal: 0.5)]
            + (1...99).map { (start: earliestReplayInput.addingTimeInterval(Double($0) * 60), basal: 1.0) }

        let inputs = try await fetch(transport)

        #expect(transport.requests(to: "profile").map(\.count) == [100, 200])
        #expect(try #require(inputs.profileHistory).timeline.count == 101)
    }

    @Test("profile history that never reaches the boundary is rejected")
    func unboundedProfileHistoryIsRejected() async throws {
        let transport = makeTransport()
        transport.unboundedProfiles = end

        await #expect(throws: TuningPipeline.PipelineError.incompleteProfileHistory(requiredFrom: earliestReplayInput)) {
            _ = try await fetch(transport)
        }
        #expect(transport.requests(to: "profile").map(\.count) == [100, 200, 400, 800, 1600, 3200])
        #expect(transport.requests(to: "entries").isEmpty)
    }

    // MARK: - Cache

    /// A finished, unexpired window and the UTC day inside it that tests fill.
    func cacheWindow() -> (end: Date, day: (key: String, interval: DateInterval)) {
        let end = Date().addingTimeInterval(-5 * 86_400)
        let dayStart = DayCache.floorToUTCDay(end.addingTimeInterval(-86_400))
        let interval = DateInterval(start: dayStart, duration: 86_400)
        return (end, (DayCache.dayKey(for: dayStart), interval))
    }

    func makeCache() -> DayCache {
        DayCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("looptune-complete-fetch-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("a day that cannot be fetched completely is not cached")
    func incompleteDayIsNotCached() async throws {
        let cache = makeCache()
        let window = cacheWindow()
        let instant = window.day.interval.start.addingTimeInterval(3600)
        let transport = makeTransport()
        transport.treatments = (0..<pageSize).map {
            (date: instant, json: CappedNightscoutTransport.bolusJSON(id: "same-\($0)", at: instant))
        }

        await #expect(throws: TuningPipeline.PipelineError.self) {
            _ = try await fetch(transport, cache: cache, endingAt: window.end)
        }
        let origin = try makeClient(transport).origin
        #expect(cache.load(origin: origin, dayKey: window.day.key) == nil)
    }

    @Test("a saturated day fetched completely is cached and reused")
    func completeSaturatedDayIsReused() async throws {
        let cache = makeCache()
        let window = cacheWindow()
        let firstTransport = makeTransport()
        firstTransport.treatments = doses(count: pageSize + 1, from: window.day.interval.start.addingTimeInterval(60), spacing: 30)

        let first = try await fetch(firstTransport, cache: cache, endingAt: window.end)
        let origin = try makeClient(firstTransport).origin
        let stored = try #require(cache.load(origin: origin, dayKey: window.day.key))
        #expect(stored.isComplete)
        #expect(stored.treatments.count == pageSize + 1)

        let secondTransport = makeTransport()
        let second = try await fetch(secondTransport, cache: cache, endingAt: window.end)
        #expect(secondTransport.requests(to: "treatments").isEmpty)
        #expect(second.doses.count == pageSize + 1)
        #expect(first.doses.count == pageSize + 1)
    }

    @Test("a day cached without a completeness mark is refetched")
    func unmarkedCachedDayIsRefetched() async throws {
        let cache = makeCache()
        let window = cacheWindow()
        let transport = makeTransport()
        transport.treatments = doses(count: pageSize + 1, from: window.day.interval.start.addingTimeInterval(60), spacing: 30)
        let origin = try makeClient(transport).origin
        // What the previous single-query fetch stored: the newest 1,500.
        let truncated = transport.treatments.sorted { $0.date > $1.date }.prefix(pageSize).map {
            try! JSONDecoder().decode(NSTreatment.self, from: Data($0.json.utf8))
        }
        cache.store(CachedDay(day: window.day.key, fetchedAt: Date(), entries: [], treatments: Array(truncated)), origin: origin)

        let inputs = try await fetch(transport, cache: cache, endingAt: window.end)

        #expect(inputs.doses.count == pageSize + 1)
        #expect(cache.load(origin: origin, dayKey: window.day.key)?.isComplete == true)
    }
}
