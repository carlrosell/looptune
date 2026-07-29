import Testing
import Foundation
@testable import LoopTuneKit

/// Records the last request and returns a canned response.
final class StubTransport: NightscoutTransport, @unchecked Sendable {
    var responseData: Data
    var statusCode: Int
    private(set) var lastRequest: URLRequest?

    init(responseData: Data = Data("[]".utf8), statusCode: Int = 200) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (responseData, response)
    }
}

@Suite("NightscoutClient URL + auth")
struct NightscoutClientRequestTests {
    @Test("normalizes messy user URLs to scheme+host")
    func normalization() throws {
        #expect(NightscoutClient.normalizeBaseURL("mysite.herokuapp.com")?.absoluteString == "https://mysite.herokuapp.com")
        #expect(NightscoutClient.normalizeBaseURL("https://mysite.com/api/v1/entries.json")?.absoluteString == "https://mysite.com")
        #expect(NightscoutClient.normalizeBaseURL("https://mysite.com/?token=abc-123")?.absoluteString == "https://mysite.com")
        #expect(NightscoutClient.normalizeBaseURL("  http://localhost:1337  ")?.absoluteString == "http://localhost:1337")
        #expect(NightscoutClient.normalizeBaseURL("http://127.0.0.1:8080")?.absoluteString == "http://127.0.0.1:8080")
        #expect(NightscoutClient.normalizeBaseURL("http://remote.example.com") == nil)
        #expect(NightscoutClient.normalizeBaseURL("ftp://remote.example.com") == nil)
        #expect(NightscoutClient.normalizeBaseURL("") == nil)
    }

    @Test("token auth adds a ?token= query item")
    func tokenAuth() throws {
        let client = try NightscoutClient(rawURLString: "https://x.com", credentials: .token("subj-hash"))
        let request = client.makeRequest(path: "/api/v1/status.json", queryItems: [])
        let url = request!.url!.absoluteString
        #expect(url.contains("token=subj-hash"))
    }

    @Test("api-secret auth sends the SHA-1 hex header, not the raw secret")
    func apiSecretAuth() throws {
        let client = try NightscoutClient(rawURLString: "https://x.com", credentials: .apiSecret("mysecret"))
        let request = client.makeRequest(path: "/api/v1/status.json", queryItems: [])
        // SHA1("mysecret") = f966f8…; verify it is NOT the raw secret and is 40 hex chars.
        let header = request!.value(forHTTPHeaderField: "api-secret")
        #expect(header != "mysecret")
        #expect(header?.count == 40)
    }

    @Test("api-secret hashes to the known SHA-1 of the secret")
    func apiSecretKnownHash() {
        // SHA1("mysecret") per `shasum -a 1`.
        let creds = NightscoutCredentials.apiSecret("mysecret")
        #expect(creds.apiSecretHeader == "e9fe51f94eadabf54dbf2fbbd57188b9abee436e")
    }

    @Test("entries request carries epoch-ms bounds and count")
    func entriesRequestShape() async throws {
        let stub = StubTransport()
        let client = try NightscoutClient(rawURLString: "https://x.com", credentials: .none, transport: stub)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = Date(timeIntervalSince1970: 1_100_000)
        _ = try await client.fetchEntries(from: start, to: end, count: 1500)
        let url = stub.lastRequest!.url!.absoluteString
        #expect(url.contains("/api/v1/entries/sgv.json"))
        #expect(url.contains("1000000000"))   // start ms
        #expect(url.contains("1100000000"))   // end ms
        #expect(url.contains("count=1500"))
    }

    @Test("unauthorized status surfaces as .unauthorized")
    func unauthorized() async throws {
        let stub = StubTransport(statusCode: 401)
        let client = try NightscoutClient(rawURLString: "https://x.com", transport: stub)
        await #expect(throws: NightscoutError.unauthorized) {
            _ = try await client.fetchStatus()
        }
    }

    @Test("partially malformed arrays fail instead of silently omitting evidence")
    func partialArrayFails() async throws {
        let stub = StubTransport(responseData: Data(#"""
        [
          {"date":1700000000000,"sgv":100},
          {"not":"an entry"}
        ]
        """#.utf8))
        let client = try NightscoutClient(rawURLString: "https://x.com", transport: stub)
        await #expect(throws: NightscoutError.partialDecoding(
            path: "/api/v1/entries/sgv.json",
            skipped: 1
        )) {
            _ = try await client.fetchEntries(
                from: Date(timeIntervalSince1970: 1_700_000_000),
                to: Date(timeIntervalSince1970: 1_700_000_300)
            )
        }
    }
}

@Suite("Nightscout DTO decoding")
struct NightscoutDTODecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test("entry decodes epoch-ms date and sgv")
    func entryDecoding() throws {
        let entry = try decode(NSEntry.self, #"{"date": 1700000000000, "sgv": 120, "type": "sgv"}"#)
        #expect(entry.sgv == 120)
        #expect(entry.date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("entry falls back to ISO dateString")
    func entryISOFallback() throws {
        let entry = try decode(NSEntry.self, #"{"dateString": "2023-11-14T22:13:20Z", "sgv": 95}"#)
        #expect(entry.sgv == 95)
    }

    @Test("temp basal treatment decodes rate/amount/duration/reason")
    func tempBasalDecoding() throws {
        let json = #"{"_id":"mongo-id","syncIdentifier":"sync-id","eventType":"Temp Basal","created_at":"2023-01-09T20:44:28Z","rate":1.75,"absolute":1.75,"amount":0.875,"duration":30.0,"temp":"absolute","automatic":true}"#
        let t = try decode(NSTreatment.self, json)
        #expect(t.identifier == "mongo-id")
        #expect(t.syncIdentifier == "sync-id")
        #expect(t.eventType == "Temp Basal")
        #expect(t.rate == 1.75)
        #expect(t.amount == 0.875)
        #expect(t.duration == 30.0)
        #expect(t.automatic == true)
    }

    @Test("treatment tolerates fractional-second timestamps and stringy numbers")
    func lenientTreatment() throws {
        let json = #"{"eventType":"Carb Correction","created_at":"2023-01-09T20:44:28.253Z","carbs":"45","absorptionTime":180}"#
        let t = try decode(NSTreatment.self, json)
        #expect(t.carbs == 45)
        #expect(t.absorptionTime == 180)
    }

    @Test("override decodes durationType and scale factor")
    func overrideDecoding() throws {
        let json = #"{"eventType":"Temporary Override","created_at":"2023-01-09T20:44:28Z","durationType":"indefinite","insulinNeedsScaleFactor":0.7,"correctionRange":[150,170]}"#
        let t = try decode(NSTreatment.self, json)
        #expect(t.durationType == "indefinite")
        #expect(t.insulinNeedsScaleFactor == 0.7)
        #expect(t.correctionRange == [150, 170])
    }

    @Test("profile document decodes store, units, loopSettings")
    func profileDecoding() throws {
        let json = #"""
        {
          "defaultProfile": "Default",
          "startDate": "2025-09-14T16:32:12Z",
          "units": "mg/dL",
          "enteredBy": "Loop",
          "store": {
            "Default": {
              "dia": 6,
              "timezone": "ETC/GMT+5",
              "basal": [{"time":"00:00","timeAsSeconds":0,"value":0.85}],
              "sens": [{"time":"00:00","timeAsSeconds":0,"value":45}],
              "carbratio": [{"time":"06:30","timeAsSeconds":23400,"value":9}]
            }
          },
          "loopSettings": {"dosingEnabled": true, "dosingStrategy": "automaticBolus", "minimumBGGuard": 75, "maximumBasalRatePerHour": 5.0, "maximumBolus": 10.0}
        }
        """#
        let doc = try decode(NSProfileDocument.self, json)
        #expect(doc.defaultProfile == "Default")
        #expect(doc.units == "mg/dL")
        let store = doc.store["Default"]
        #expect(store?.basal.first?.value == 0.85)
        #expect(store?.carbratio.first?.timeAsSeconds == 23400)
        #expect(doc.loopSettings?.dosingStrategy == "automaticBolus")
        #expect(doc.loopSettings?.minimumBGGuard == 75)
    }

    @Test("schedule item derives seconds from HH:mm when timeAsSeconds absent")
    func scheduleItemHHmm() throws {
        let item = try decode(NSScheduleItem.self, #"{"time":"06:30","value":9}"#)
        #expect(item.timeAsSeconds == 23400)
    }

    @Test("schedule items reject missing values, invalid clock times, and overflowing integers")
    func scheduleItemValidation() {
        #expect(throws: (any Error).self) {
            _ = try decode(NSScheduleItem.self, #"{"time":"25:00","value":9}"#)
        }
        #expect(throws: (any Error).self) {
            _ = try decode(NSScheduleItem.self, #"{"time":"06:30"}"#)
        }
        #expect(throws: (any Error).self) {
            _ = try decode(
                NSScheduleItem.self,
                #"{"timeAsSeconds":"999999999999999999999999999999","value":9}"#
            )
        }
    }

    @Test("status document exposes units")
    func statusDecoding() throws {
        let status = try decode(NSStatus.self, #"{"version":"14.2.6","settings":{"units":"mmol"}}"#)
        #expect(status.settings?.units == "mmol")
    }
}
