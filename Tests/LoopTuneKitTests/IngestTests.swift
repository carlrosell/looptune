import Testing
import Foundation
@testable import LoopTuneKit

@Suite("ProfileIngest")
struct ProfileIngestTests {
    private func decodeDoc(_ json: String) throws -> NSProfileDocument {
        try JSONDecoder().decode(NSProfileDocument.self, from: Data(json.utf8))
    }

    @Test("builds a profile from a Loop mg/dL document")
    func mgdlProfile() throws {
        let doc = try decodeDoc(#"""
        {
          "defaultProfile":"Default","units":"mg/dL","startDate":"2025-09-14T16:32:12Z",
          "store":{"Default":{
            "timezone":"America/New_York",
            "basal":[{"timeAsSeconds":0,"value":0.85},{"timeAsSeconds":21600,"value":1.0}],
            "sens":[{"timeAsSeconds":0,"value":45}],
            "carbratio":[{"timeAsSeconds":0,"value":9}],
            "target_low":[{"timeAsSeconds":0,"value":95}],
            "target_high":[{"timeAsSeconds":0,"value":105}]
          }},
          "loopSettings":{"dosingStrategy":"automaticBolus","minimumBGGuard":75}
        }
        """#)
        let profile = try ProfileIngest.makeProfile(from: doc)
        #expect(profile.glucoseUnit == .milligramsPerDeciliter)
        #expect(profile.timeZone.identifier == "America/New_York")
        #expect(profile.basalSchedule.value(atSecondsSinceMidnight: 0) == 0.85)
        #expect(profile.basalSchedule.value(atSecondsSinceMidnight: 21600) == 1.0)
        #expect(profile.sensitivitySchedule.value(atSecondsSinceMidnight: 0) == 45)
        #expect(profile.dosingStrategy == .automaticBolus)
        #expect(profile.suspendThresholdMilligramsPerDeciliter == 75)
        let target = profile.targetSchedule.value(atSecondsSinceMidnight: 0)
        #expect(target == 95...105)
    }

    @Test("converts mmol/L ISF, targets and suspend threshold to mg/dL")
    func mmolConversion() throws {
        let doc = try decodeDoc(#"""
        {
          "defaultProfile":"Default","units":"mmol/L",
          "store":{"Default":{
            "timezone":"UTC",
            "basal":[{"timeAsSeconds":0,"value":0.85}],
            "sens":[{"timeAsSeconds":0,"value":2.5}],
            "carbratio":[{"timeAsSeconds":0,"value":9}],
            "target_low":[{"timeAsSeconds":0,"value":5.0}],
            "target_high":[{"timeAsSeconds":0,"value":6.0}]
          }},
          "loopSettings":{"minimumBGGuard":4.0}
        }
        """#)
        let profile = try ProfileIngest.makeProfile(from: doc)
        // 2.5 mmol/L/U * 18.0156 ≈ 45.04 mg/dL/U
        #expect(abs(profile.sensitivitySchedule.value(atSecondsSinceMidnight: 0) - 45.039) < 0.01)
        // CR is never converted.
        #expect(profile.carbRatioSchedule.value(atSecondsSinceMidnight: 0) == 9)
        let target = profile.targetSchedule.value(atSecondsSinceMidnight: 0)
        #expect(abs(target.lowerBound - 90.078) < 0.01)
        #expect(abs(target.upperBound - 108.093) < 0.01)
        #expect(abs((profile.suspendThresholdMilligramsPerDeciliter ?? 0) - 72.062) < 0.01)
    }

    @Test("resolves ETC/GMT timezone with inverted sign")
    func etcGmtTimezone() throws {
        let doc = try decodeDoc(#"""
        {"defaultProfile":"Default","units":"mg/dL","store":{"Default":{
          "timezone":"ETC/GMT+5",
          "basal":[{"timeAsSeconds":0,"value":0.85}],
          "sens":[{"timeAsSeconds":0,"value":45}],
          "carbratio":[{"timeAsSeconds":0,"value":9}],
          "target_low":[{"timeAsSeconds":0,"value":95}],"target_high":[{"timeAsSeconds":0,"value":105}]
        }}}
        """#)
        let profile = try ProfileIngest.makeProfile(from: doc)
        #expect(profile.timeZone.secondsFromGMT() == -5 * 3600)
    }

    @Test("throws when the store is missing")
    func missingStore() throws {
        let doc = try decodeDoc(#"{"defaultProfile":"Default","store":{}}"#)
        #expect(throws: ProfileIngest.IngestError.noStore) {
            _ = try ProfileIngest.makeProfile(from: doc)
        }
    }

    @Test("rejects missing or unknown units and invalid timezones")
    func strictUnitsAndTimezone() throws {
        let missingUnits = try decodeDoc(#"""
        {"defaultProfile":"Default","store":{"Default":{
          "timezone":"UTC",
          "basal":[{"timeAsSeconds":0,"value":1}],
          "sens":[{"timeAsSeconds":0,"value":50}],
          "carbratio":[{"timeAsSeconds":0,"value":10}],
          "target_low":[{"timeAsSeconds":0,"value":100}],
          "target_high":[{"timeAsSeconds":0,"value":110}]
        }}}
        """#)
        #expect(throws: ProfileIngest.IngestError.unknownGlucoseUnit(nil)) {
            _ = try ProfileIngest.makeProfile(from: missingUnits)
        }

        let badZone = try decodeDoc(#"""
        {"defaultProfile":"Default","units":"bananas","store":{"Default":{
          "timezone":"Moon/Base",
          "basal":[{"timeAsSeconds":0,"value":1}],
          "sens":[{"timeAsSeconds":0,"value":50}],
          "carbratio":[{"timeAsSeconds":0,"value":10}],
          "target_low":[{"timeAsSeconds":0,"value":100}],
          "target_high":[{"timeAsSeconds":0,"value":110}]
        }}}
        """#)
        #expect(throws: ProfileIngest.IngestError.unknownGlucoseUnit("bananas")) {
            _ = try ProfileIngest.makeProfile(from: badZone)
        }

        let invalidZoneJSON = #"""
        {"defaultProfile":"Default","units":"mg/dL","store":{"Default":{
          "timezone":"Moon/Base",
          "basal":[{"timeAsSeconds":0,"value":1}],
          "sens":[{"timeAsSeconds":0,"value":50}],
          "carbratio":[{"timeAsSeconds":0,"value":10}],
          "target_low":[{"timeAsSeconds":0,"value":100}],
          "target_high":[{"timeAsSeconds":0,"value":110}]
        }}}
        """#
        let invalidZone = try decodeDoc(invalidZoneJSON)
        #expect(throws: ProfileIngest.IngestError.invalidTimeZone("Moon/Base")) {
            _ = try ProfileIngest.makeProfile(from: invalidZone)
        }
    }

    @Test("rejects nonphysical profile schedule and guardrail values")
    func rejectsInvalidValues() throws {
        let doc = try decodeDoc(#"""
        {"defaultProfile":"Default","units":"mg/dL","store":{"Default":{
          "timezone":"UTC",
          "basal":[{"timeAsSeconds":0,"value":-1}],
          "sens":[{"timeAsSeconds":0,"value":50}],
          "carbratio":[{"timeAsSeconds":0,"value":10}],
          "target_low":[{"timeAsSeconds":0,"value":100}],
          "target_high":[{"timeAsSeconds":0,"value":110}]
        }}}
        """#)
        #expect(throws: ProfileIngest.IngestError.invalidValue("basal")) {
            _ = try ProfileIngest.makeProfile(from: doc)
        }
    }
}

@Suite("TreatmentIngest")
struct TreatmentIngestTests {
    private func decode(_ json: String) throws -> [NSTreatment] {
        try JSONDecoder().decode([NSTreatment].self, from: Data(json.utf8))
    }

    @Test("bolus uses delivered insulin and retains automatic flag")
    func bolusIngest() throws {
        let treatments = try decode(#"""
        [{"eventType":"Correction Bolus","created_at":"2023-01-09T20:44:28Z","insulin":2.35,"programmed":2.5,"automatic":true,"insulinType":"Humalog"}]
        """#)
        let result = TreatmentIngest.ingest(treatments)
        #expect(result.doses.count == 1)
        #expect(result.doses[0].kind == .bolus(units: 2.35))
        #expect(result.doses[0].automatic == true)
        #expect(result.doses[0].insulinType == .humalog)
    }

    @Test("temp basal effective rate prefers amount/duration")
    func tempEffectiveRate() throws {
        let treatments = try decode(#"""
        [{"eventType":"Temp Basal","created_at":"2023-01-09T20:00:00Z","rate":1.75,"amount":0.875,"duration":30.0,"temp":"absolute"}]
        """#)
        let result = TreatmentIngest.ingest(treatments)
        #expect(result.doses.count == 1)
        // amount 0.875 over 0.5h = 1.75 U/hr effective; delivered = 0.875 U.
        #expect(abs(result.doses[0].deliveredUnits - 0.875) < 1e-9)
        if case .tempBasal(let rate) = result.doses[0].kind {
            #expect(abs(rate - 1.75) < 1e-9)
        } else {
            Issue.record("expected temp basal")
        }
    }

    @Test("zero-rate suspend becomes a suspend dose")
    func suspendIngest() throws {
        let treatments = try decode(#"""
        [{"eventType":"Temp Basal","created_at":"2023-01-09T20:00:00Z","rate":0,"absolute":0,"duration":60.0,"reason":"suspend"}]
        """#)
        let result = TreatmentIngest.ingest(treatments)
        #expect(result.doses.count == 1)
        #expect(result.doses[0].kind == .suspend)
        #expect(result.doses[0].deliveredUnits == 0)
    }

    @Test("overlapping temp basals are trimmed to the next start")
    func overlapTrimming() throws {
        let treatments = try decode(#"""
        [
          {"eventType":"Temp Basal","created_at":"2023-01-09T20:00:00Z","rate":1.0,"duration":30.0,"temp":"absolute"},
          {"eventType":"Temp Basal","created_at":"2023-01-09T20:05:00Z","rate":2.0,"duration":30.0,"temp":"absolute"}
        ]
        """#)
        let result = TreatmentIngest.ingest(treatments)
        #expect(result.doses.count == 2)
        // First temp clipped from 30 min to 5 min (ends where the second starts).
        let first = result.doses[0]
        #expect(first.endDate.timeIntervalSince(first.startDate) == 5 * 60)
    }

    @Test("percentage temp without absolute rate is skipped")
    func skipPercentTemp() throws {
        let treatments = try decode(#"""
        [{"eventType":"Temp Basal","created_at":"2023-01-09T20:00:00Z","temp":"percent","percent":120,"duration":30.0}]
        """#)
        let result = TreatmentIngest.ingest(treatments)
        #expect(result.doses.isEmpty)
    }

    @Test("carbs are ingested with minutes→seconds absorption and deduped")
    func carbIngest() throws {
        let treatments = try decode(#"""
        [
          {"eventType":"Carb Correction","created_at":"2023-01-09T12:00:00Z","carbs":45,"absorptionTime":180},
          {"eventType":"Carb Correction","created_at":"2023-01-09T12:00:01Z","carbs":45}
        ]
        """#)
        let result = TreatmentIngest.ingest(treatments)
        #expect(result.carbs.count == 1)     // second is a ±2s duplicate
        #expect(result.carbs[0].grams == 45)
        #expect(result.carbs[0].absorptionTime == 180 * 60)
    }

    @Test("carb absent absorptionTime defaults to 3h")
    func carbDefaultAbsorption() throws {
        let treatments = try decode(#"""
        [{"eventType":"Carb Correction","created_at":"2023-01-09T12:00:00Z","carbs":20}]
        """#)
        let result = TreatmentIngest.ingest(treatments)
        #expect(result.carbs[0].absorptionTime == 3 * 3600)
    }

    @Test("meal bolus carrying both insulin and carbs yields a dose and a carb")
    func mealBolusBoth() throws {
        let treatments = try decode(#"""
        [{"eventType":"Meal Bolus","created_at":"2023-01-09T12:00:00Z","insulin":3.0,"carbs":30}]
        """#)
        let result = TreatmentIngest.ingest(treatments)
        #expect(result.doses.count == 1)
        #expect(result.carbs.count == 1)
    }

    @Test("indefinite override is closed at the next override start")
    func indefiniteOverride() throws {
        let treatments = try decode(#"""
        [
          {"eventType":"Temporary Override","created_at":"2023-01-09T08:00:00Z","durationType":"indefinite","insulinNeedsScaleFactor":0.8},
          {"eventType":"Temporary Override","created_at":"2023-01-09T10:00:00Z","duration":60,"insulinNeedsScaleFactor":0.7,"correctionRange":[150,170]}
        ]
        """#)
        let result = TreatmentIngest.ingest(treatments)
        #expect(result.overrides.count == 2)
        #expect(result.overrides[0].endDate == result.overrides[1].startDate)
        #expect(result.overrides[0].insulinNeedsScaleFactor == 0.8)
        #expect(result.overrides[1].correctionRangeMilligramsPerDeciliter == 150...170)
        #expect(result.overrides[1].affectsInsulinNeeds == true)
    }

    @Test("non-finite treatment values are rejected during decoding")
    func rejectsNonFiniteValues() throws {
        #expect(throws: (any Error).self) {
            _ = try decode(#"""
        [
          {"eventType":"Correction Bolus","created_at":"2023-01-09T20:00:00Z","insulin":"NaN"},
          {"eventType":"Carb Correction","created_at":"2023-01-09T20:05:00Z","carbs":"Infinity"},
          {"eventType":"Temp Basal","created_at":"2023-01-09T20:10:00Z","duration":30,"rate":"NaN"}
        ]
        """#)
        }
    }
}

@Suite("GlucoseIngest")
struct GlucoseIngestTests {
    private func decode(_ json: String) throws -> [NSEntry] {
        try JSONDecoder().decode([NSEntry].self, from: Data(json.utf8))
    }

    @Test("filters sensor errors, sorts, and dedupes")
    func filtering() throws {
        let entries = try decode(#"""
        [
          {"date": 1700000300000, "sgv": 120, "type": "sgv"},
          {"date": 1700000000000, "sgv": 100, "type": "sgv"},
          {"date": 1700000000000, "sgv": 100, "type": "sgv"},
          {"date": 1700000600000, "sgv": 5, "type": "sgv"}
        ]
        """#)
        let samples = GlucoseIngest.ingest(entries)
        #expect(samples.count == 2)                       // sgv=5 dropped, dup removed
        #expect(samples[0].milligramsPerDeciliter == 100) // sorted ascending
        #expect(samples[1].milligramsPerDeciliter == 120)
    }
}
