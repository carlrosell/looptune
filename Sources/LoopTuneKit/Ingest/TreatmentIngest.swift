import Foundation

/// Normalized output of treatment ingestion.
public struct IngestedTreatments: Sendable, Equatable {
    public var doses: [DoseRecord]
    public var carbs: [CarbRecord]
    public var overrides: [OverridePeriod]

    public init(doses: [DoseRecord] = [], carbs: [CarbRecord] = [], overrides: [OverridePeriod] = []) {
        self.doses = doses
        self.carbs = carbs
        self.overrides = overrides
    }
}

/// Converts Nightscout treatment documents into domain dose/carb/override
/// records, handling the messy realities documented in the research notes:
/// Loop's effective-rate `amount`, zero-rate suspends, overlapping re-uploaded
/// temp basals, duplicate carbs, and indefinite overrides.
public enum TreatmentIngest {
    /// Duplicate-carb tolerance (oref0 dedupes carbs within ±2s).
    static let carbDedupeTolerance: TimeInterval = 2

    public static func ingest(_ treatments: [NSTreatment]) -> IngestedTreatments {
        var boluses: [DoseRecord] = []
        var tempRecords: [DoseRecord] = []
        var carbs: [CarbRecord] = []
        var overrides: [OverridePeriod] = []

        for treatment in treatments {
            let type = treatment.eventType ?? ""

            // Boluses: any treatment carrying delivered insulin (Loop marks all
            // boluses "Correction Bolus"; other uploaders vary).
            if let dose = bolus(from: treatment) {
                boluses.append(dose)
            }

            // Carbs: any treatment carrying carbs (Carb Correction, or Meal Bolus
            // carrying both insulin and carbs).
            if let carb = carb(from: treatment) {
                carbs.append(carb)
            }

            if type == "Temp Basal" || treatment.temp != nil {
                if let temp = tempBasal(from: treatment) {
                    tempRecords.append(temp)
                }
            } else if type == "Temporary Override" {
                overrides.append(overridePeriod(from: treatment))
            }
        }

        let trimmedTemps = trimOverlaps(tempRecords)
        let dedupedCarbs = dedupeCarbs(carbs)
        let resolvedOverrides = resolveIndefiniteOverrides(overrides)

        let allDoses = (boluses + trimmedTemps).sorted { $0.startDate < $1.startDate }
        return IngestedTreatments(doses: allDoses, carbs: dedupedCarbs, overrides: resolvedOverrides)
    }

    // MARK: - Boluses

    static func bolus(from treatment: NSTreatment) -> DoseRecord? {
        // Use delivered `insulin`, not `programmed` (interrupted boluses differ).
        guard let insulin = treatment.insulin, insulin.isFinite, insulin > 0 else { return nil }
        let start = treatment.createdAt
        // `duration` (minutes) is nonzero for square/extended boluses.
        let durationMinutes = treatment.duration.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        } ?? 0
        let end = start.addingTimeInterval(max(0, durationMinutes) * 60)
        return DoseRecord(
            kind: .bolus(units: insulin),
            startDate: start,
            endDate: end,
            automatic: treatment.automatic ?? false,
            insulinType: insulinType(from: treatment.insulinType)
        )
    }

    // MARK: - Temp basals / suspends

    static func tempBasal(from treatment: NSTreatment) -> DoseRecord? {
        guard let durationMinutes = treatment.duration,
              durationMinutes.isFinite,
              durationMinutes > 0 else { return nil }
        // Skip percentage temps that lack an absolute rate (not usable for replay).
        if treatment.temp == "percent", treatment.rate == nil, treatment.absolute == nil, treatment.amount == nil {
            return nil
        }
        let start = treatment.createdAt
        let end = start.addingTimeInterval(durationMinutes * 60)

        // Suspend: explicit reason, or a zero programmed rate.
        let isSuspend = (treatment.reason?.lowercased() == "suspend")
            || (treatment.rate == 0 && (treatment.absolute ?? 0) == 0 && (treatment.amount ?? 0) == 0)
        if isSuspend {
            return DoseRecord(kind: .suspend, startDate: start, endDate: end, automatic: treatment.automatic ?? false, insulinType: insulinType(from: treatment.insulinType))
        }

        // Effective delivered rate: prefer amount/duration (what actually ran),
        // then programmed rate, then absolute.
        let effectiveRate: Double
        if let amount = treatment.amount, amount.isFinite, amount >= 0 {
            effectiveRate = amount / (durationMinutes / 60)
        } else if let rate = treatment.rate, rate.isFinite, rate >= 0 {
            effectiveRate = rate
        } else if let absolute = treatment.absolute, absolute.isFinite, absolute >= 0 {
            effectiveRate = absolute
        } else {
            return nil
        }

        return DoseRecord(
            kind: .tempBasal(unitsPerHour: effectiveRate),
            startDate: start,
            endDate: end,
            automatic: treatment.automatic ?? false,
            insulinType: insulinType(from: treatment.insulinType)
        )
    }

    /// Sort temp/suspend records by start and clip each so it never overlaps the
    /// next (later record wins) — Loop re-uploads mutating temp basals, which can
    /// otherwise appear as overlapping duplicates.
    static func trimOverlaps(_ records: [DoseRecord]) -> [DoseRecord] {
        let sorted = records.sorted { $0.startDate < $1.startDate }
        var result: [DoseRecord] = []
        for (index, record) in sorted.enumerated() {
            var trimmed = record
            if index + 1 < sorted.count {
                let nextStart = sorted[index + 1].startDate
                if trimmed.endDate > nextStart {
                    trimmed.endDate = nextStart
                }
            }
            // Drop records clipped to zero/negative length.
            guard trimmed.endDate > trimmed.startDate else { continue }
            result.append(trimmed)
        }
        return result
    }

    // MARK: - Carbs

    static func carb(from treatment: NSTreatment) -> CarbRecord? {
        guard let grams = treatment.carbs, grams.isFinite, grams > 0 else { return nil }
        let absorption = treatment.absorptionTime.flatMap {
            $0.isFinite && $0 > 0 ? $0 * 60 : nil
        } ?? CarbRecord.defaultAbsorptionTime
        return CarbRecord(date: treatment.createdAt, grams: grams, absorptionTime: absorption, foodType: treatment.foodType)
    }

    static func dedupeCarbs(_ carbs: [CarbRecord]) -> [CarbRecord] {
        let sorted = carbs.sorted { $0.date < $1.date }
        var result: [CarbRecord] = []
        for carb in sorted {
            if let last = result.last,
               abs(carb.date.timeIntervalSince(last.date)) <= carbDedupeTolerance,
               carb.grams == last.grams {
                continue
            }
            result.append(carb)
        }
        return result
    }

    // MARK: - Overrides

    static func overridePeriod(from treatment: NSTreatment) -> OverridePeriod {
        let start = treatment.createdAt
        let isIndefinite = treatment.durationType?.lowercased() == "indefinite"
        let end: Date?
        if isIndefinite {
            end = nil
        } else if let durationMinutes = treatment.duration,
                  durationMinutes.isFinite,
                  durationMinutes > 0 {
            end = start.addingTimeInterval(durationMinutes * 60)
        } else {
            end = nil
        }
        // Loop uploads override `correctionRange` in mg/dL by convention,
        // regardless of the site's display units (see research note 06 §1.4), so
        // it is stored as-is without unit conversion. Non-Loop uploaders that
        // emit mmol/L override ranges are out of scope for v1.
        let range: ClosedRange<Double>?
        if let bounds = treatment.correctionRange,
           bounds.count == 2,
           bounds.allSatisfy({ $0.isFinite && $0 > 0 }) {
            range = min(bounds[0], bounds[1])...max(bounds[0], bounds[1])
        } else {
            range = nil
        }
        return OverridePeriod(
            startDate: start,
            endDate: end,
            insulinNeedsScaleFactor: treatment.insulinNeedsScaleFactor.flatMap {
                $0.isFinite && $0 > 0 ? $0 : nil
            },
            correctionRangeMilligramsPerDeciliter: range,
            reason: treatment.reason
        )
    }

    /// Close indefinite overrides at the start of the next override.
    static func resolveIndefiniteOverrides(_ overrides: [OverridePeriod]) -> [OverridePeriod] {
        let sorted = overrides.sorted { $0.startDate < $1.startDate }
        var result: [OverridePeriod] = []
        for (index, override) in sorted.enumerated() {
            var resolved = override
            if resolved.endDate == nil, index + 1 < sorted.count {
                resolved.endDate = sorted[index + 1].startDate
            }
            result.append(resolved)
        }
        return result
    }

    static func insulinType(from raw: String?) -> InsulinType? {
        guard let raw else { return nil }
        return InsulinType(rawValue: raw.lowercased())
    }
}
