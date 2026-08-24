import Testing
import Foundation
import LoopAlgorithm
@testable import LoopTuneKit

@Suite("Domain → LoopAlgorithm adapters")
struct DomainAdapterTests {
    @Test("bolus becomes a bolus dose with full volume")
    func bolusAdapter() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let dose = DoseRecord(kind: .bolus(units: 2.5), startDate: start, endDate: start)
        let fixture = dose.fixture(defaultInsulinType: .novolog)
        #expect(fixture.deliveryType == .bolus)
        #expect(fixture.volume == 2.5)
        #expect(dose.deliveredUnits == 2.5)
    }

    @Test("temp basal volume = effective rate × hours")
    func tempBasalAdapter() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let dose = DoseRecord(kind: .tempBasal(unitsPerHour: 1.2), startDate: start, endDate: start.addingTimeInterval(1800))
        #expect(abs(dose.deliveredUnits - 0.6) < 1e-9)
        let fixture = dose.fixture(defaultInsulinType: .novolog)
        #expect(fixture.deliveryType == .basal)
        #expect(abs(fixture.volume - 0.6) < 1e-9)
    }

    @Test("suspend is a zero-volume basal dose")
    func suspendAdapter() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let dose = DoseRecord(kind: .suspend, startDate: start, endDate: start.addingTimeInterval(3600))
        #expect(dose.deliveredUnits == 0)
        let fixture = dose.fixture(defaultInsulinType: nil)
        #expect(fixture.deliveryType == .basal)
        #expect(fixture.volume == 0)
    }

    @Test("per-dose insulin type overrides the default")
    func insulinTypeOverride() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let dose = DoseRecord(kind: .bolus(units: 1), startDate: start, endDate: start, insulinType: .fiasp)
        #expect(dose.fixture(defaultInsulinType: .novolog).insulinType == FixtureInsulinType.fiasp)
    }

    @Test("carb record adapts with default absorption time")
    func carbAdapter() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let carb = CarbRecord(date: start, grams: 45)
        #expect(carb.absorptionTime == 3 * 3600)
        let fixture = carb.fixture()
        #expect(fixture.quantity.doubleValue(for: .gram) == 45)
        #expect(fixture.absorptionTime == TimeInterval(3 * 3600))
    }

    @Test("glucose sample unifies provenance for replay")
    func glucoseProvenance() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = GlucoseSample(date: start, milligramsPerDeciliter: 120, provenance: "some-device")
        #expect(sample.fixture(unifyProvenance: true).provenanceIdentifier == FixtureGlucoseSample.defaultProvenanceIdentifier)
        #expect(sample.fixture(unifyProvenance: false).provenanceIdentifier == "some-device")
        #expect(sample.fixture().quantity.doubleValue(for: .milligramsPerDeciliter) == 120)
    }
}

@Suite("TherapyProfile timelines")
struct TherapyProfileTests {
    private func makeProfile() throws -> TherapyProfile {
        TherapyProfile(
            basalSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 0.8)]),
            sensitivitySchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 50)]),
            carbRatioSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 10)]),
            targetSchedule: try DailySchedule(entries: [.init(secondsSinceMidnight: 0, value: 100...115)]),
            timeZone: TimeZone(identifier: "UTC")!,
            glucoseUnit: .milligramsPerDeciliter
        )
    }

    @Test("expands all schedule timelines over a window")
    func timelines() throws {
        let profile = try makeProfile()
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(24 * 3600)

        let basal = profile.basalTimeline(from: start, to: end)
        #expect(basal.count == 1)
        #expect(basal[0].value == 0.8)

        let isf = profile.sensitivityTimeline(from: start, to: end)
        #expect(isf[0].value.doubleValue(for: .milligramsPerDeciliter) == 50)

        let cr = profile.carbRatioTimeline(from: start, to: end)
        #expect(cr[0].value == 10)

        let target = profile.targetTimeline(from: start, to: end)
        #expect(target[0].value.lowerBound.doubleValue(for: .milligramsPerDeciliter) == 100)
        #expect(target[0].value.upperBound.doubleValue(for: .milligramsPerDeciliter) == 115)
    }

    @Test("schedule-aware replacement keeps ISF and carb-ratio time blocks")
    func scheduleAwareReplacement() throws {
        let sensitivity = try DailySchedule(entries: [
            .init(secondsSinceMidnight: 0, value: 48.0),
            .init(secondsSinceMidnight: 8 * 3600, value: 55.0),
        ])
        let carbRatio = try DailySchedule(entries: [
            .init(secondsSinceMidnight: 0, value: 9.0),
            .init(secondsSinceMidnight: 11 * 3600, value: 11.0),
        ])
        let replaced = try makeProfile().replacing(
            basalHourly: Array(repeating: 0.9, count: 24),
            sensitivitySchedule: sensitivity,
            carbRatioSchedule: carbRatio
        )

        #expect(replaced.sensitivitySchedule == sensitivity)
        #expect(replaced.carbRatioSchedule == carbRatio)
        #expect(replaced.basalSchedule.hourlyValues() == Array(repeating: 0.9, count: 24))
    }
}
