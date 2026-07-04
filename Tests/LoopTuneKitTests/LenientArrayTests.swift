import Testing
import Foundation
@testable import LoopTuneKit

@Suite("LenientArray + hardening")
struct LenientArrayTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> [T] {
        try JSONDecoder().decode(LenientArray<T>.self, from: Data(json.utf8)).elements
    }

    @Test("skips a malformed entry but keeps the rest")
    func skipsBadEntry() throws {
        // Middle entry lacks a usable date and sgv → skipped.
        let json = #"""
        [
          {"date": 1700000000000, "sgv": 100, "type": "sgv"},
          {"foo": "bar"},
          {"date": 1700000300000, "sgv": 120, "type": "sgv"}
        ]
        """#
        let entries = try decode(NSEntry.self, json)
        #expect(entries.count == 2)
        #expect(entries[0].sgv == 100)
        #expect(entries[1].sgv == 120)
    }

    @Test("entry with non-finite sgv is rejected at decode")
    func rejectsNonFiniteSGV() throws {
        // sgv as the string "NaN" → non-finite → element skipped by LenientArray.
        let json = #"[{"date": 1700000000000, "sgv": "NaN", "type": "sgv"}]"#
        let entries = try decode(NSEntry.self, json)
        #expect(entries.isEmpty)
    }

    @Test("empty array decodes to empty")
    func emptyArray() throws {
        #expect(try decode(NSEntry.self, "[]").isEmpty)
    }
}

@Suite("Hardening: timezone HHMM + target offset guard")
struct HardeningTests {
    @Test("parses whole-hour and HHMM GMT offsets via the fallback")
    func gmtOffsetForms() {
        // Whole-hour ETC form (inverted sign).
        #expect(NightscoutTimeZone.fixedOffsetSeconds(from: "ETC/GMT+5") == -5 * 3600)
        // HHMM plain-GMT form.
        #expect(NightscoutTimeZone.fixedOffsetSeconds(from: "GMT+0230") == 2 * 3600 + 30 * 60)
        // Out-of-range magnitude rejected.
        #expect(NightscoutTimeZone.fixedOffsetSeconds(from: "GMT+9999") == nil)
    }

    @Test("target schedule with mismatched low/high offsets is rejected")
    func mismatchedTargetOffsets() throws {
        let json = #"""
        {"defaultProfile":"Default","units":"mg/dL","store":{"Default":{
          "timezone":"UTC",
          "basal":[{"timeAsSeconds":0,"value":0.85}],
          "sens":[{"timeAsSeconds":0,"value":45}],
          "carbratio":[{"timeAsSeconds":0,"value":9}],
          "target_low":[{"timeAsSeconds":0,"value":95},{"timeAsSeconds":3600,"value":100}],
          "target_high":[{"timeAsSeconds":0,"value":105},{"timeAsSeconds":7200,"value":110}]
        }}}
        """#
        let doc = try JSONDecoder().decode(NSProfileDocument.self, from: Data(json.utf8))
        #expect(throws: ProfileIngest.IngestError.badSchedule("target")) {
            _ = try ProfileIngest.makeProfile(from: doc)
        }
    }
}
