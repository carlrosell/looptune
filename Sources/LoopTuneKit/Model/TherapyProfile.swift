import Foundation
import LoopAlgorithm

/// Loop's insulin dosing strategy, as reported in the Nightscout profile's
/// `loopSettings.dosingStrategy`.
public enum DosingStrategy: String, Sendable, Codable {
    case automaticBolus
    case tempBasalOnly
}

/// A user's therapy settings at a point in time, normalized from a Nightscout
/// profile document. All glucose-denominated values are stored in mg/dL.
public struct TherapyProfile: Sendable, Equatable {
    /// U/hr by time of day.
    public var basalSchedule: DailySchedule<Double>
    /// Insulin sensitivity in mg/dL per U by time of day.
    public var sensitivitySchedule: DailySchedule<Double>
    /// Carb ratio in g per U by time of day.
    public var carbRatioSchedule: DailySchedule<Double>
    /// Correction range in mg/dL by time of day.
    public var targetSchedule: DailySchedule<ClosedRange<Double>>

    public var timeZone: TimeZone
    /// The profile's display units (glucose values above are always mg/dL).
    public var glucoseUnit: GlucoseUnit

    /// When this profile document became active (Nightscout `startDate`), used
    /// to pick the profile in force on each analyzed day.
    public var activeFrom: Date?

    // Loop settings (optional — present only for Loop-sourced profiles).
    public var dosingStrategy: DosingStrategy?
    /// Suspend threshold / glucose safety limit in mg/dL.
    public var suspendThresholdMilligramsPerDeciliter: Double?
    public var maximumBasalRatePerHour: Double?
    public var maximumBolus: Double?
    /// The insulin brand Loop is configured with; drives the exponential model.
    public var insulinType: InsulinType?

    public init(
        basalSchedule: DailySchedule<Double>,
        sensitivitySchedule: DailySchedule<Double>,
        carbRatioSchedule: DailySchedule<Double>,
        targetSchedule: DailySchedule<ClosedRange<Double>>,
        timeZone: TimeZone,
        glucoseUnit: GlucoseUnit,
        activeFrom: Date? = nil,
        dosingStrategy: DosingStrategy? = nil,
        suspendThresholdMilligramsPerDeciliter: Double? = nil,
        maximumBasalRatePerHour: Double? = nil,
        maximumBolus: Double? = nil,
        insulinType: InsulinType? = nil
    ) {
        self.basalSchedule = basalSchedule
        self.sensitivitySchedule = sensitivitySchedule
        self.carbRatioSchedule = carbRatioSchedule
        self.targetSchedule = targetSchedule
        self.timeZone = timeZone
        self.glucoseUnit = glucoseUnit
        self.activeFrom = activeFrom
        self.dosingStrategy = dosingStrategy
        self.suspendThresholdMilligramsPerDeciliter = suspendThresholdMilligramsPerDeciliter
        self.maximumBasalRatePerHour = maximumBasalRatePerHour
        self.maximumBolus = maximumBolus
        self.insulinType = insulinType
    }

    // MARK: - LoopAlgorithm timeline adapters

    /// Scheduled basal (U/hr) as an absolute timeline tiling `[start, end]`.
    public func basalTimeline(from start: Date, to end: Date) -> [AbsoluteScheduleValue<Double>] {
        basalSchedule.expand(from: start, to: end, timeZone: timeZone)
    }

    /// ISF as an absolute timeline of `LoopQuantity` (mg/dL/U).
    public func sensitivityTimeline(from start: Date, to end: Date) -> [AbsoluteScheduleValue<LoopQuantity>] {
        sensitivitySchedule.expand(from: start, to: end, timeZone: timeZone).map {
            AbsoluteScheduleValue(
                startDate: $0.startDate,
                endDate: $0.endDate,
                value: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: $0.value)
            )
        }
    }

    /// Carb ratio (g/U) as an absolute timeline.
    public func carbRatioTimeline(from start: Date, to end: Date) -> [AbsoluteScheduleValue<Double>] {
        carbRatioSchedule.expand(from: start, to: end, timeZone: timeZone)
    }

    /// Correction range (mg/dL) as a LoopAlgorithm `GlucoseRangeTimeline`.
    public func targetTimeline(from start: Date, to end: Date) -> [AbsoluteScheduleValue<ClosedRange<LoopQuantity>>] {
        targetSchedule.expand(from: start, to: end, timeZone: timeZone).map {
            let low = LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: $0.value.lowerBound)
            let high = LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: $0.value.upperBound)
            return AbsoluteScheduleValue(startDate: $0.startDate, endDate: $0.endDate, value: low...high)
        }
    }
}
