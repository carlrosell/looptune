import Testing
import Foundation
@testable import LoopTuneKit

@Suite("GlucoseUnit")
struct GlucoseUnitTests {
    @Test("parses Nightscout unit strings case-insensitively")
    func parsing() {
        #expect(GlucoseUnit(nightscoutString: "mg/dl") == .milligramsPerDeciliter)
        #expect(GlucoseUnit(nightscoutString: "mg/dL") == .milligramsPerDeciliter)
        #expect(GlucoseUnit(nightscoutString: "mmol") == .millimolesPerLiter)
        #expect(GlucoseUnit(nightscoutString: "mmol/l") == .millimolesPerLiter)
        #expect(GlucoseUnit(nightscoutString: "mmol/L") == .millimolesPerLiter)
        #expect(GlucoseUnit(nightscoutString: "mmol\u{00a0}/L") == .millimolesPerLiter)
        #expect(GlucoseUnit(nightscoutString: nil) == .milligramsPerDeciliter)
    }

    @Test("converts mmol/L to mg/dL and back")
    func conversion() {
        let mmol = GlucoseUnit.millimolesPerLiter
        // 5.5 mmol/L ≈ 99.1 mg/dL
        let mgdl = mmol.toMilligramsPerDeciliter(5.5)
        #expect(abs(mgdl - 99.086) < 0.01)
        #expect(abs(mmol.fromMilligramsPerDeciliter(mgdl) - 5.5) < 1e-9)
    }

    @Test("mg/dL conversions are identities")
    func mgdlIdentity() {
        let unit = GlucoseUnit.milligramsPerDeciliter
        #expect(unit.toMilligramsPerDeciliter(100) == 100)
        #expect(unit.fromMilligramsPerDeciliter(100) == 100)
    }
}

@Suite("NightscoutTimeZone")
struct NightscoutTimeZoneTests {
    @Test("passes through canonical IANA identifiers")
    func iana() {
        #expect(NightscoutTimeZone.parse("Europe/Stockholm")?.identifier == "Europe/Stockholm")
        #expect(NightscoutTimeZone.parse("America/New_York")?.identifier == "America/New_York")
    }

    @Test("handles POSIX ETC/GMT with inverted sign")
    func etcGmtInverted() {
        // ETC/GMT+5 means UTC-5.
        #expect(NightscoutTimeZone.parse("ETC/GMT+5")?.secondsFromGMT() == -5 * 3600)
        // ETC/GMT-2 means UTC+2 (Loop maps GMT+0200 -> ETC/GMT-2).
        #expect(NightscoutTimeZone.parse("ETC/GMT-2")?.secondsFromGMT() == 2 * 3600)
        #expect(NightscoutTimeZone.parse("Etc/GMT+0")?.secondsFromGMT() == 0)
    }

    @Test("handles plain GMT offset strings without inversion")
    func plainGmt() {
        #expect(NightscoutTimeZone.parse("GMT+0200")?.secondsFromGMT() == 2 * 3600)
    }

    @Test("returns nil for unintelligible input")
    func nilForGarbage() {
        #expect(NightscoutTimeZone.parse("not-a-zone") == nil)
        #expect(NightscoutTimeZone.parse("") == nil)
        #expect(NightscoutTimeZone.parse(nil) == nil)
    }
}
