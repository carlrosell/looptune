import Testing
import Foundation
@testable import LoopTuneKit

/// Golden parity tests against outputs produced by oref0's REAL autotune core
/// (`lib/autotune/index.js`, `tuneAllTheThings`) at oref0 commit 88cf032.
///
/// Fixtures live in `Fixtures/oref0/` and are regenerated with
/// `node references/gen_oref0_fixtures.js` (see the README next to them).
/// These pin LoopTune's ISF and basal tuning math to the reference
/// implementation, including its rounding and smoothing quirks.
@Suite("oref0 parity")
struct Oref0ParityTests {
    struct Fixture: Decodable {
        struct Input: Decodable {
            var isf: Double
            var pumpISF: Double
            var carbRatio: Double
            var pumpCarbRatio: Double
            var basalHourly: [Double]
            var pumpBasalHourly: [Double]
            var prepped: Prepped
        }
        struct Prepped: Decodable {
            var ISFGlucoseData: [Datum]
            var basalGlucoseData: [Datum]
        }
        struct Datum: Decodable {
            var date: Double
            var glucose: Double
            var BGI: Double
            var deviation: String
            var avgDelta: String
        }
        struct Expected: Decodable {
            var sens: Double
            var carb_ratio: Double
            var basalHourly: [Double]
            var untuned: [Int]
        }
        var input: Input
        var expected: Expected
    }

    private func loadFixture(_ name: String) throws -> Fixture {
        let url = Bundle.module.url(forResource: "Fixtures/oref0/\(name)", withExtension: "json")
            ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/oref0")
        let data = try Data(contentsOf: #require(url))
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private func categorized(_ data: [Fixture.Datum], as category: DeviationCategory) -> [CategorizedSample] {
        data.map { datum in
            let sample = DeviationSample(
                date: Date(timeIntervalSince1970: datum.date / 1000),
                glucose: datum.glucose,
                averageDelta: Double(datum.avgDelta) ?? 0,
                insulinEffect: datum.BGI,
                deviation: Double(datum.deviation) ?? 0,
                insulinOnBoard: 0,
                carbsOnBoard: 0
            )
            return CategorizedSample(sample: sample, category: category, scheduledBasal: 1.0, scheduledISF: 50)
        }
    }

    private func runScenario(_ name: String) throws {
        let fixture = try loadFixture(name)
        let samples = categorized(fixture.input.prepped.ISFGlucoseData, as: .isf)
            + categorized(fixture.input.prepped.basalGlucoseData, as: .basal)

        // ISF parity.
        let tunedISF = SensitivityTuner().tune(
            samples: samples,
            currentISF: fixture.input.isf,
            pumpISF: fixture.input.pumpISF
        )
        #expect(abs(tunedISF - fixture.expected.sens) < 0.001, "ISF mismatch in \(name): got \(tunedISF), oref0 says \(fixture.expected.sens)")

        // Basal parity (fixtures are generated with TZ=UTC).
        let basalResult = BasalTuner(timeZone: TimeZone(identifier: "UTC")!).tune(
            samples: samples,
            currentHourly: fixture.input.basalHourly,
            pumpHourly: fixture.input.pumpBasalHourly,
            isf: fixture.input.isf
        )
        for hour in 0..<24 {
            #expect(
                abs(basalResult.hourlyRates[hour] - fixture.expected.basalHourly[hour]) < 0.001,
                "basal mismatch in \(name) hour \(hour): got \(basalResult.hourlyRates[hour]), oref0 says \(fixture.expected.basalHourly[hour])"
            )
            #expect(
                basalResult.untuned[hour] == (fixture.expected.untuned[hour] > 0),
                "untuned flag mismatch in \(name) hour \(hour)"
            )
        }
    }

    @Test("isf_positive: median-ratio ISF matches oref0 exactly")
    func isfPositive() throws {
        try runScenario("isf_positive")
    }

    @Test("basal_positive: per-hour basal distribution and smoothing match oref0 exactly")
    func basalPositive() throws {
        try runScenario("basal_positive")
    }

    @Test("mixed: combined positive/negative scenario matches oref0 exactly")
    func mixed() throws {
        try runScenario("mixed")
    }
}
