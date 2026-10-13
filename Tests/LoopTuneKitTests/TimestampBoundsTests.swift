import Testing
import Foundation
@testable import LoopTuneKit

@Suite("Timestamp bounds")
struct TimestampBoundsTests {
    /// 0001-01-01T00:00:00Z and 9999-12-31T23:59:59.999Z in epoch milliseconds.
    static let earliestMillis: Int64 = -62_135_596_800_000
    static let latestMillis: Int64 = 253_402_300_799_999
    /// Far past `Int64` milliseconds: the value that trapped `DayCache.store`.
    let unrepresentable = Date(timeIntervalSince1970: 1e27)
    let site = SiteOrigin(url: URL(string: "https://site.example.com")!)!

    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func makeCache() -> DayCache {
        DayCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("looptune-timestamp-bounds-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("epoch dates outside the range are rejected, not clamped or replaced", arguments: [
        "1e30", "-1e30", "\"1e30\"", "\"NaN\"", "253402300800000", "-62135596800001",
    ])
    func outOfRangeEpochIsRejected(date: String) {
        #expect(throws: DecodingError.self) {
            try decode(NSEntry.self, #"{"date":\#(date),"sgv":120}"#)
        }
        // An out-of-range `date` does not fall back to `dateString`.
        #expect(throws: DecodingError.self) {
            try decode(NSEntry.self, #"{"date":\#(date),"dateString":"2023-11-14T22:13:20Z","sgv":120}"#)
        }
        #expect(throws: DecodingError.self) {
            try decode(NSTreatment.self, #"{"eventType":"Correction Bolus","created_at":\#(date),"insulin":1}"#)
        }
        #expect(throws: DecodingError.self) {
            try decode(NSProfileDocument.self, #"{"startDate":\#(date),"store":{}}"#)
        }
    }

    @Test("a network array with one out-of-range timestamp is a partial decode")
    func arrayReportsSkippedTimestamp() throws {
        let decoded = try JSONDecoder().decode(
            LenientArray<NSEntry>.self,
            from: Data(#"[{"date":1700000000000,"sgv":100},{"date":1e30,"sgv":120}]"#.utf8)
        )
        #expect(decoded.elements.map(\.sgv) == [100])
        #expect(decoded.skippedCount == 1)
    }

    @Test("dates at both ends of the range round-trip exactly through the cache format")
    func boundsRoundTrip() throws {
        for millis in [Self.earliestMillis, 1_700_000_000_000, Self.latestMillis] {
            let entry = try decode(NSEntry.self, #"{"date":\#(millis),"sgv":120}"#)
            #expect(NightscoutDate.epochMilliseconds(entry.date) == millis)
            #expect(try decode(NSEntry.self, String(decoding: JSONEncoder().encode(entry), as: UTF8.self)) == entry)

            let treatment = try decode(NSTreatment.self, #"{"eventType":"Correction Bolus","created_at":\#(millis),"insulin":1}"#)
            let reencoded = try decode(NSTreatment.self, String(decoding: JSONEncoder().encode(treatment), as: UTF8.self))
            #expect(NightscoutDate.epochMilliseconds(reencoded.createdAt) == millis)
        }
    }

    @Test("encoding an unrepresentable date throws instead of trapping")
    func encodingIsChecked() {
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(NSEntry(date: unrepresentable, sgv: 120))
        }
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(NSTreatment(eventType: "Correction Bolus", createdAt: unrepresentable, insulin: 1))
        }
        // Just past the range: Int64 holds it, but it would not decode back.
        let beyondLatest = Date(timeIntervalSince1970: Double(Self.latestMillis + 1) / 1000)
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(NSEntry(date: beyondLatest, sgv: 120))
        }
    }

    @Test("a cache write of an unrepresentable date is skipped")
    func cacheStoreFailsSafely() {
        let cache = makeCache()
        let day = CachedDay(
            day: "2023-11-14",
            fetchedAt: Date(),
            entries: [NSEntry(date: unrepresentable, sgv: 120)],
            treatments: [],
            isComplete: true
        )
        cache.store(day, origin: site)
        #expect(cache.load(origin: site, dayKey: "2023-11-14") == nil)
    }

    // Exit tests need Swift 6.2; CI still builds with 6.1.
    #if compiler(>=6.2)
    @Test("storing the audit's oversized entry does not terminate the process")
    func cacheStoreDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("looptune-timestamp-bounds-\(UUID().uuidString)", isDirectory: true)
            let entry = NSEntry(date: Date(timeIntervalSince1970: 1e27), sgv: 120)
            DayCache(directory: directory).store(
                CachedDay(day: "2023-11-14", fetchedAt: Date(), entries: [entry], treatments: [], isComplete: true),
                origin: SiteOrigin(url: URL(string: "https://site.example.com")!)!
            )
        }
    }
    #endif
}
