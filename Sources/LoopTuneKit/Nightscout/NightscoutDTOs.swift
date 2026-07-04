import Foundation

/// Raw Nightscout document shapes. These decode the wire format leniently; the
/// Ingest layer turns them into LoopTune's domain model.

// MARK: - Entries (CGM)

/// A Nightscout `entries` document. `sgv` values are always mg/dL.
public struct NSEntry: Sendable, Equatable {
    public var date: Date
    public var sgv: Double
    public var type: String?
    public var device: String?
}

extension NSEntry: Decodable {
    private enum CodingKeys: String, CodingKey {
        case date, dateString, sgv, type, device
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Prefer epoch-ms `date`; fall back to ISO `dateString`.
        if let millis = container.lenientDouble(forKey: .date) {
            date = NightscoutDate.fromEpochMilliseconds(millis)
        } else if let iso = container.lenientString(forKey: .dateString), let parsed = NightscoutDate.parseISO(iso) {
            date = parsed
        } else {
            throw DecodingError.dataCorruptedError(forKey: .date, in: container, debugDescription: "entry has no usable date")
        }
        sgv = container.lenientDouble(forKey: .sgv) ?? .nan
        type = container.lenientString(forKey: .type)
        device = container.lenientString(forKey: .device)
    }
}

// MARK: - Treatments

/// A Nightscout `treatments` document. A single decoded shape covers boluses,
/// carbs, temp basals, suspends, and overrides; the Ingest layer dispatches on
/// `eventType`.
public struct NSTreatment: Sendable, Equatable {
    public var eventType: String?
    public var createdAt: Date
    public var enteredBy: String?

    // Bolus
    public var insulin: Double?
    public var programmed: Double?

    // Temp basal
    public var rate: Double?
    public var absolute: Double?
    public var amount: Double?
    public var duration: Double?     // minutes
    public var temp: String?         // "absolute" | "percent"
    public var reason: String?
    public var automatic: Bool?

    // Carbs
    public var carbs: Double?
    public var absorptionTime: Double?  // minutes
    public var foodType: String?

    // Override
    public var durationType: String?
    public var insulinNeedsScaleFactor: Double?
    public var correctionRange: [Double]?

    public var insulinType: String?
}

extension NSTreatment: Decodable {
    private enum CodingKeys: String, CodingKey {
        case eventType, created_at, timestamp, enteredBy
        case insulin, programmed
        case rate, absolute, amount, duration, temp, reason, automatic
        case carbs, absorptionTime, foodType
        case durationType, insulinNeedsScaleFactor, correctionRange
        case insulinType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = container.lenientString(forKey: .eventType)

        if let iso = container.lenientString(forKey: .created_at), let parsed = NightscoutDate.parseISO(iso) {
            createdAt = parsed
        } else if let iso = container.lenientString(forKey: .timestamp), let parsed = NightscoutDate.parseISO(iso) {
            createdAt = parsed
        } else if let millis = container.lenientDouble(forKey: .created_at) {
            createdAt = NightscoutDate.fromEpochMilliseconds(millis)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .created_at, in: container, debugDescription: "treatment has no usable created_at")
        }

        enteredBy = container.lenientString(forKey: .enteredBy)
        insulin = container.lenientDouble(forKey: .insulin)
        programmed = container.lenientDouble(forKey: .programmed)
        rate = container.lenientDouble(forKey: .rate)
        absolute = container.lenientDouble(forKey: .absolute)
        amount = container.lenientDouble(forKey: .amount)
        duration = container.lenientDouble(forKey: .duration)
        temp = container.lenientString(forKey: .temp)
        reason = container.lenientString(forKey: .reason)
        automatic = container.lenientBool(forKey: .automatic)
        carbs = container.lenientDouble(forKey: .carbs)
        absorptionTime = container.lenientDouble(forKey: .absorptionTime)
        foodType = container.lenientString(forKey: .foodType)
        durationType = container.lenientString(forKey: .durationType)
        insulinNeedsScaleFactor = container.lenientDouble(forKey: .insulinNeedsScaleFactor)
        correctionRange = (try? container.decodeIfPresent([Double].self, forKey: .correctionRange)) ?? nil
        insulinType = container.lenientString(forKey: .insulinType)
    }
}

// MARK: - Profile

/// A single schedule item (`{time, timeAsSeconds, value}`) from a profile store.
public struct NSScheduleItem: Sendable, Equatable {
    public var timeAsSeconds: Int
    public var value: Double
}

extension NSScheduleItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case time, timeAsSeconds, value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let seconds = container.lenientInt(forKey: .timeAsSeconds) {
            timeAsSeconds = seconds
        } else if let time = container.lenientString(forKey: .time), let seconds = Self.secondsFromHHmm(time) {
            timeAsSeconds = seconds
        } else {
            throw DecodingError.dataCorruptedError(forKey: .timeAsSeconds, in: container, debugDescription: "schedule item has no time")
        }
        value = container.lenientDouble(forKey: .value) ?? 0
    }

    static func secondsFromHHmm(_ string: String) -> Int? {
        let parts = string.split(separator: ":").map { Int($0) }
        guard parts.count >= 2, let hour = parts[0], let minute = parts[1] else { return nil }
        return hour * 3600 + minute * 60
    }
}

/// A profile store entry (`store.<name>`).
public struct NSProfileStore: Sendable, Equatable, Decodable {
    public var dia: Double?
    public var units: String?
    public var timezone: String?
    public var basal: [NSScheduleItem]
    public var sens: [NSScheduleItem]
    public var carbratio: [NSScheduleItem]
    public var target_low: [NSScheduleItem]?
    public var target_high: [NSScheduleItem]?
}

/// Loop-specific settings block, present only on Loop-sourced profiles.
public struct NSLoopSettings: Sendable, Equatable, Decodable {
    public var dosingEnabled: Bool?
    public var dosingStrategy: String?
    public var minimumBGGuard: Double?
    public var maximumBasalRatePerHour: Double?
    public var maximumBolus: Double?
}

/// A Nightscout `profile` document.
public struct NSProfileDocument: Sendable, Equatable {
    public var defaultProfile: String?
    public var startDate: Date?
    public var units: String?
    public var enteredBy: String?
    public var store: [String: NSProfileStore]
    public var loopSettings: NSLoopSettings?
}

extension NSProfileDocument: Decodable {
    private enum CodingKeys: String, CodingKey {
        case defaultProfile, startDate, units, enteredBy, store, loopSettings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultProfile = container.lenientString(forKey: .defaultProfile)
        if let iso = container.lenientString(forKey: .startDate) {
            startDate = NightscoutDate.parseISO(iso)
        } else if let millis = container.lenientDouble(forKey: .startDate) {
            startDate = NightscoutDate.fromEpochMilliseconds(millis)
        } else {
            startDate = nil
        }
        units = container.lenientString(forKey: .units)
        enteredBy = container.lenientString(forKey: .enteredBy)
        store = (try? container.decodeIfPresent([String: NSProfileStore].self, forKey: .store)) ?? [:]
        loopSettings = try? container.decodeIfPresent(NSLoopSettings.self, forKey: .loopSettings)
    }
}

// MARK: - Status

/// A Nightscout `status` document (subset), used for units/capability detection.
public struct NSStatus: Sendable, Equatable, Decodable {
    public struct Settings: Sendable, Equatable, Decodable {
        public var units: String?
    }
    public var version: String?
    public var settings: Settings?
}
