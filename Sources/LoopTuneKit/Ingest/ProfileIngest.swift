import Foundation

/// The history of a user's therapy profiles, built from Nightscout's profile
/// documents (Loop uploads a new document on every settings change, with
/// `startDate` marking when it became active).
public struct ProfileHistory: Sendable {
    /// Profiles with a known activation date, ascending by `activeFrom`.
    public let timeline: [TherapyProfile]
    /// The newest profile — what is in Loop right now.
    public let current: TherapyProfile

    public init(timeline: [TherapyProfile], current: TherapyProfile) {
        self.timeline = timeline.sorted { ($0.activeFrom ?? .distantPast) < ($1.activeFrom ?? .distantPast) }
        self.current = current
    }

    /// The profile that was active at `date`: the latest one activated at or
    /// before it, falling back to the earliest known (best effort), then to
    /// the current profile.
    public func activeProfile(at date: Date) -> TherapyProfile {
        var result: TherapyProfile?
        for profile in timeline {
            guard let activeFrom = profile.activeFrom else { continue }
            if activeFrom <= date {
                result = profile
            } else {
                break
            }
        }
        return result ?? timeline.first ?? current
    }

    /// Return a history in which every profile missing an insulin model uses
    /// the user's configured model. Nightscout profile documents do not carry
    /// this setting, but historical replay is just as dependent on it as replay
    /// against the current profile.
    public func applyingDefaultInsulinType(_ insulinType: InsulinType) -> ProfileHistory {
        func applying(to profile: TherapyProfile) -> TherapyProfile {
            var copy = profile
            if copy.insulinType == nil {
                copy.insulinType = insulinType
            }
            return copy
        }
        return ProfileHistory(
            timeline: timeline.map(applying),
            current: applying(to: current)
        )
    }
}

public extension TherapyProfile {
    /// Whether two profiles agree on the tuning-relevant settings (basal, ISF,
    /// carb ratio schedules). Loop uploads a new document for *any* settings
    /// change, including ones that don't affect replay (targets, max bolus) —
    /// those must not count as therapy changes.
    func hasSameTherapySettings(as other: TherapyProfile) -> Bool {
        basalSchedule == other.basalSchedule
            && sensitivitySchedule == other.sensitivitySchedule
            && carbRatioSchedule == other.carbRatioSchedule
            && timeZone == other.timeZone
            && insulinType == other.insulinType
    }
}

/// Converts a Nightscout profile document into LoopTune's `TherapyProfile`.
public enum ProfileIngest {
    public enum IngestError: Error, Equatable {
        case noStore
        case unknownGlucoseUnit(String?)
        case invalidTimeZone(String?)
        case emptySchedule(String)
        case badSchedule(String)
        case invalidValue(String)
    }

    /// Build a `ProfileHistory` from profile documents (newest first, as
    /// `/api/v1/profile.json` returns them). Every document is validated:
    /// silently dropping a malformed historical profile would replay part of
    /// the analysis window against settings that were never active.
    public static func makeHistory(from docs: [NSProfileDocument]) throws -> ProfileHistory {
        let parsed = try docs.map(makeProfile)
        guard let current = parsed.first else { throw IngestError.noStore }
        let dated = parsed.filter { $0.activeFrom != nil }
        return ProfileHistory(timeline: dated, current: current)
    }

    /// Build a `TherapyProfile` from a profile document. Glucose-denominated
    /// values (`sens`, targets, `minimumBGGuard`) are converted from the
    /// profile's display units into mg/dL.
    public static func makeProfile(from doc: NSProfileDocument) throws -> TherapyProfile {
        // Resolve the active store: Loop always uses `defaultProfile` ("Default").
        let storeName = doc.defaultProfile ?? doc.store.keys.sorted().first
        guard let storeName, let store = doc.store[storeName] else {
            throw IngestError.noStore
        }

        // Units precedence: per-profile store units, then top-level document units.
        let rawUnit = store.units ?? doc.units
        guard let unit = GlucoseUnit.parseNightscout(rawUnit) else {
            throw IngestError.unknownGlucoseUnit(rawUnit)
        }

        guard let timeZone = NightscoutTimeZone.parse(store.timezone) else {
            throw IngestError.invalidTimeZone(store.timezone)
        }

        let basalSchedule = try schedule(from: store.basal, name: "basal", isValid: { $0 >= 0 }) { $0 }
        let sensitivitySchedule = try schedule(from: store.sens, name: "sens", isValid: { $0 > 0 }) {
            unit.toMilligramsPerDeciliter($0)
        }
        let carbRatioSchedule = try schedule(from: store.carbratio, name: "carbratio", isValid: { $0 > 0 }) { $0 }
        let targetSchedule = try makeTargetSchedule(low: store.target_low, high: store.target_high, unit: unit)

        let dosingStrategy = doc.loopSettings?.dosingStrategy.flatMap(DosingStrategy.init(rawValue:))
        let suspendThreshold = doc.loopSettings?.minimumBGGuard.map { unit.toMilligramsPerDeciliter($0) }
        try validateOptional(suspendThreshold, name: "minimumBGGuard", allowsZero: false)
        try validateOptional(doc.loopSettings?.maximumBasalRatePerHour, name: "maximumBasalRatePerHour", allowsZero: false)
        try validateOptional(doc.loopSettings?.maximumBolus, name: "maximumBolus", allowsZero: true)

        return TherapyProfile(
            basalSchedule: basalSchedule,
            sensitivitySchedule: sensitivitySchedule,
            carbRatioSchedule: carbRatioSchedule,
            targetSchedule: targetSchedule,
            timeZone: timeZone,
            glucoseUnit: unit,
            activeFrom: doc.startDate,
            dosingStrategy: dosingStrategy,
            suspendThresholdMilligramsPerDeciliter: suspendThreshold,
            maximumBasalRatePerHour: doc.loopSettings?.maximumBasalRatePerHour,
            maximumBolus: doc.loopSettings?.maximumBolus
        )
    }

    private static func schedule(
        from items: [NSScheduleItem],
        name: String,
        isValid: (Double) -> Bool,
        transform: (Double) -> Double
    ) throws -> DailySchedule<Double> {
        guard !items.isEmpty else { throw IngestError.emptySchedule(name) }
        let entries = try items.map {
            let value = transform($0.value)
            guard value.isFinite, isValid(value) else {
                throw IngestError.invalidValue(name)
            }
            return DailySchedule<Double>.Entry(secondsSinceMidnight: $0.timeAsSeconds, value: value)
        }
        do {
            return try DailySchedule(entries: entries)
        } catch {
            throw IngestError.badSchedule(name)
        }
    }

    private static func makeTargetSchedule(
        low: [NSScheduleItem]?,
        high: [NSScheduleItem]?,
        unit: GlucoseUnit
    ) throws -> DailySchedule<ClosedRange<Double>> {
        let lows = low ?? []
        let highs = high ?? []
        guard !lows.isEmpty, lows.count == highs.count else {
            throw IngestError.badSchedule("target")
        }
        // Nightscout stores target_low and target_high as parallel arrays sharing
        // the same offsets.
        var entries: [DailySchedule<ClosedRange<Double>>.Entry] = []
        for (lowItem, highItem) in zip(lows.sorted { $0.timeAsSeconds < $1.timeAsSeconds },
                                       highs.sorted { $0.timeAsSeconds < $1.timeAsSeconds }) {
            // The low/high arrays must share the same offsets; pairing mismatched
            // times would silently corrupt the target schedule.
            guard lowItem.timeAsSeconds == highItem.timeAsSeconds else {
                throw IngestError.badSchedule("target")
            }
            let lowMgdl = unit.toMilligramsPerDeciliter(lowItem.value)
            let highMgdl = unit.toMilligramsPerDeciliter(highItem.value)
            guard lowMgdl.isFinite, highMgdl.isFinite,
                  lowMgdl > 0, highMgdl > 0, lowMgdl <= highMgdl else {
                throw IngestError.invalidValue("target")
            }
            entries.append(.init(secondsSinceMidnight: lowItem.timeAsSeconds, value: lowMgdl...highMgdl))
        }
        do {
            return try DailySchedule(entries: entries)
        } catch {
            throw IngestError.badSchedule("target")
        }
    }

    private static func validateOptional(
        _ value: Double?,
        name: String,
        allowsZero: Bool
    ) throws {
        guard let value else { return }
        guard value.isFinite, allowsZero ? value >= 0 : value > 0 else {
            throw IngestError.invalidValue(name)
        }
    }
}
