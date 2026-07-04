import Foundation

/// Converts a Nightscout profile document into LoopTune's `TherapyProfile`.
public enum ProfileIngest {
    public enum IngestError: Error, Equatable {
        case noStore
        case emptySchedule(String)
        case badSchedule(String)
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
        let unit = GlucoseUnit(nightscoutString: store.units ?? doc.units)

        let timeZone = NightscoutTimeZone.parse(store.timezone) ?? TimeZone(identifier: "UTC")!

        let basalSchedule = try schedule(from: store.basal, name: "basal") { $0 }
        let sensitivitySchedule = try schedule(from: store.sens, name: "sens") { unit.toMilligramsPerDeciliter($0) }
        let carbRatioSchedule = try schedule(from: store.carbratio, name: "carbratio") { $0 }
        let targetSchedule = try makeTargetSchedule(low: store.target_low, high: store.target_high, unit: unit)

        let dosingStrategy = doc.loopSettings?.dosingStrategy.flatMap(DosingStrategy.init(rawValue:))
        let suspendThreshold = doc.loopSettings?.minimumBGGuard.map { unit.toMilligramsPerDeciliter($0) }

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
        transform: (Double) -> Double
    ) throws -> DailySchedule<Double> {
        guard !items.isEmpty else { throw IngestError.emptySchedule(name) }
        let entries = items.map {
            DailySchedule<Double>.Entry(secondsSinceMidnight: $0.timeAsSeconds, value: transform($0.value))
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
            entries.append(.init(secondsSinceMidnight: lowItem.timeAsSeconds, value: min(lowMgdl, highMgdl)...max(lowMgdl, highMgdl)))
        }
        do {
            return try DailySchedule(entries: entries)
        } catch {
            throw IngestError.badSchedule("target")
        }
    }
}
