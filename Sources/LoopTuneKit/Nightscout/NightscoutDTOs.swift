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

extension NSEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case date, dateString, sgv, type, device
    }

    /// Encodes back to Nightscout wire format (epoch-ms `date`), so cached
    /// documents round-trip through the same lenient decoder as live fetches.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Int((date.timeIntervalSince1970 * 1000).rounded()), forKey: .date)
        try container.encode(sgv, forKey: .sgv)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(device, forKey: .device)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Prefer epoch-ms `date`; fall back to ISO `dateString`.
        if let millis = container.lenientDouble(forKey: .date),
           let parsed = NightscoutDate.fromEpochMilliseconds(millis) {
            date = parsed
        } else if let iso = container.lenientString(forKey: .dateString), let parsed = NightscoutDate.parseISO(iso) {
            date = parsed
        } else {
            throw DecodingError.dataCorruptedError(forKey: .date, in: container, debugDescription: "entry has no usable date")
        }
        // Reject missing/non-finite glucose loudly rather than storing a NaN
        // sentinel. Batch fetches decode leniently (see `LenientArray`), so one
        // malformed entry is skipped rather than failing the whole response.
        guard let decodedSGV = container.lenientDouble(forKey: .sgv), decodedSGV.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .sgv, in: container, debugDescription: "entry has no usable sgv")
        }
        sgv = decodedSGV
        type = container.lenientString(forKey: .type)
        device = container.lenientString(forKey: .device)
    }
}

// MARK: - Treatments

/// A Nightscout `treatments` document. A single decoded shape covers boluses,
/// carbs, temp basals, suspends, and overrides; the Ingest layer dispatches on
/// `eventType`.
public struct NSTreatment: Sendable, Equatable {
    /// Stable identifiers used to deduplicate inclusive Nightscout queries.
    public var identifier: String?
    public var syncIdentifier: String?
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

extension NSTreatment: Codable {
    private enum CodingKeys: String, CodingKey {
        case identifier = "_id"
        case syncIdentifier
        case eventType, created_at, timestamp, enteredBy
        case insulin, programmed
        case rate, absolute, amount, duration, temp, reason, automatic
        case carbs, absorptionTime, foodType
        case durationType, insulinNeedsScaleFactor, correctionRange
        case insulinType
    }

    // ISO8601DateFormatter is documented thread-safe for formatting.
    nonisolated(unsafe) private static let isoEncoder: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Encodes back to Nightscout wire format (ISO `created_at`), so cached
    /// documents round-trip through the same lenient decoder as live fetches.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(identifier, forKey: .identifier)
        try container.encodeIfPresent(syncIdentifier, forKey: .syncIdentifier)
        try container.encodeIfPresent(eventType, forKey: .eventType)
        try container.encode(Self.isoEncoder.string(from: createdAt), forKey: .created_at)
        try container.encodeIfPresent(enteredBy, forKey: .enteredBy)
        try container.encodeIfPresent(insulin, forKey: .insulin)
        try container.encodeIfPresent(programmed, forKey: .programmed)
        try container.encodeIfPresent(rate, forKey: .rate)
        try container.encodeIfPresent(absolute, forKey: .absolute)
        try container.encodeIfPresent(amount, forKey: .amount)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(temp, forKey: .temp)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(automatic, forKey: .automatic)
        try container.encodeIfPresent(carbs, forKey: .carbs)
        try container.encodeIfPresent(absorptionTime, forKey: .absorptionTime)
        try container.encodeIfPresent(foodType, forKey: .foodType)
        try container.encodeIfPresent(durationType, forKey: .durationType)
        try container.encodeIfPresent(insulinNeedsScaleFactor, forKey: .insulinNeedsScaleFactor)
        try container.encodeIfPresent(correctionRange, forKey: .correctionRange)
        try container.encodeIfPresent(insulinType, forKey: .insulinType)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = container.lenientString(forKey: .identifier)
        syncIdentifier = container.lenientString(forKey: .syncIdentifier)
        eventType = container.lenientString(forKey: .eventType)

        if let iso = container.lenientString(forKey: .created_at), let parsed = NightscoutDate.parseISO(iso) {
            createdAt = parsed
        } else if let iso = container.lenientString(forKey: .timestamp), let parsed = NightscoutDate.parseISO(iso) {
            createdAt = parsed
        } else if let millis = container.lenientDouble(forKey: .created_at),
                  let parsed = NightscoutDate.fromEpochMilliseconds(millis) {
            createdAt = parsed
        } else {
            throw DecodingError.dataCorruptedError(forKey: .created_at, in: container, debugDescription: "treatment has no usable created_at")
        }

        enteredBy = container.lenientString(forKey: .enteredBy)
        insulin = try container.finiteLenientDouble(forKey: .insulin)
        programmed = try container.finiteLenientDouble(forKey: .programmed)
        rate = try container.finiteLenientDouble(forKey: .rate)
        absolute = try container.finiteLenientDouble(forKey: .absolute)
        amount = try container.finiteLenientDouble(forKey: .amount)
        duration = try container.finiteLenientDouble(forKey: .duration)
        temp = container.lenientString(forKey: .temp)
        reason = container.lenientString(forKey: .reason)
        automatic = container.lenientBool(forKey: .automatic)
        carbs = try container.finiteLenientDouble(forKey: .carbs)
        absorptionTime = try container.finiteLenientDouble(forKey: .absorptionTime)
        foodType = container.lenientString(forKey: .foodType)
        durationType = container.lenientString(forKey: .durationType)
        insulinNeedsScaleFactor = try container.finiteLenientDouble(forKey: .insulinNeedsScaleFactor)
        correctionRange = try container.decodeIfPresent([Double].self, forKey: .correctionRange)
        if let correctionRange, !correctionRange.allSatisfy(\.isFinite) {
            throw DecodingError.dataCorruptedError(
                forKey: .correctionRange,
                in: container,
                debugDescription: "correction range contains a non-finite value"
            )
        }
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
        guard (0..<86_400).contains(timeAsSeconds) else {
            throw DecodingError.dataCorruptedError(
                forKey: .timeAsSeconds,
                in: container,
                debugDescription: "schedule time must be in 0..<86400"
            )
        }
        guard let decodedValue = container.lenientDouble(forKey: .value), decodedValue.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: "schedule item has no finite value"
            )
        }
        value = decodedValue
    }

    static func secondsFromHHmm(_ string: String) -> Int? {
        let parts = string.split(separator: ":").map { Int($0) }
        guard (2...3).contains(parts.count),
              let hour = parts[0], (0..<24).contains(hour),
              let minute = parts[1], (0..<60).contains(minute) else { return nil }
        let second = parts.count == 3 ? parts[2] : 0
        guard let second, (0..<60).contains(second) else { return nil }
        return hour * 3600 + minute * 60 + second
    }
}

/// A profile store entry (`store.<name>`).
public struct NSProfileStore: Sendable, Equatable {
    public var dia: Double?
    public var units: String?
    public var timezone: String?
    public var basal: [NSScheduleItem]
    public var sens: [NSScheduleItem]
    public var carbratio: [NSScheduleItem]
    public var target_low: [NSScheduleItem]?
    public var target_high: [NSScheduleItem]?
}

extension NSProfileStore: Decodable {
    private enum CodingKeys: String, CodingKey {
        case dia, units, timezone, basal, sens, carbratio, target_low, target_high
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dia = try container.finiteLenientDouble(forKey: .dia)
        units = container.lenientString(forKey: .units)
        timezone = container.lenientString(forKey: .timezone)
        basal = try container.decode([NSScheduleItem].self, forKey: .basal)
        sens = try container.decode([NSScheduleItem].self, forKey: .sens)
        carbratio = try container.decode([NSScheduleItem].self, forKey: .carbratio)
        target_low = try container.decodeIfPresent([NSScheduleItem].self, forKey: .target_low)
        target_high = try container.decodeIfPresent([NSScheduleItem].self, forKey: .target_high)
    }
}

/// Loop-specific settings block, present only on Loop-sourced profiles.
public struct NSLoopSettings: Sendable, Equatable {
    public var dosingEnabled: Bool?
    public var dosingStrategy: String?
    public var minimumBGGuard: Double?
    public var maximumBasalRatePerHour: Double?
    public var maximumBolus: Double?
}

extension NSLoopSettings: Decodable {
    private enum CodingKeys: String, CodingKey {
        case dosingEnabled, dosingStrategy, minimumBGGuard
        case maximumBasalRatePerHour, maximumBolus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dosingEnabled = try container.strictLenientBool(forKey: .dosingEnabled)
        dosingStrategy = container.lenientString(forKey: .dosingStrategy)
        minimumBGGuard = try container.finiteLenientDouble(forKey: .minimumBGGuard)
        maximumBasalRatePerHour = try container.finiteLenientDouble(forKey: .maximumBasalRatePerHour)
        maximumBolus = try container.finiteLenientDouble(forKey: .maximumBolus)
    }
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
            guard let parsed = NightscoutDate.parseISO(iso) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .startDate,
                    in: container,
                    debugDescription: "profile startDate is malformed"
                )
            }
            startDate = parsed
        } else if let millis = container.lenientDouble(forKey: .startDate) {
            startDate = NightscoutDate.fromEpochMilliseconds(millis)
        } else {
            startDate = nil
        }
        units = container.lenientString(forKey: .units)
        enteredBy = container.lenientString(forKey: .enteredBy)
        store = try container.decodeIfPresent([String: NSProfileStore].self, forKey: .store) ?? [:]
        loopSettings = try container.decodeIfPresent(NSLoopSettings.self, forKey: .loopSettings)
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
