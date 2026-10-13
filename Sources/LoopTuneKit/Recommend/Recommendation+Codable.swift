import Foundation

// Codable conformances so a full recommendation can be persisted and reloaded
// (the run history). Values are stored verbatim rather than recomputed, so a
// reloaded run renders identically to when it was produced.

extension ChangeTier: Codable {}
extension LoopGuardrails.Status: Codable {}
extension DeviationCategory: Codable {}

/// The largest five-minute interval count whose duration in minutes fits in
/// an `Int`. No real run holds more, so a saved count above it is corrupt.
let maximumEvidenceIntervals = Int.max / 5

extension KeyedDecodingContainer {
    /// Decodes an evidence count in five-minute intervals, rejecting a value
    /// too large to be real.
    func decodeEvidenceIntervals(forKey key: Key) throws -> Int {
        try validEvidenceIntervals(decode(Int.self, forKey: key), forKey: key)
    }

    func decodeEvidenceIntervalsIfPresent(forKey key: Key) throws -> Int? {
        try decodeIfPresent(Int.self, forKey: key).map { try validEvidenceIntervals($0, forKey: key) }
    }

    private func validEvidenceIntervals(_ intervals: Int, forKey key: Key) throws -> Int {
        guard intervals <= maximumEvidenceIntervals else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Evidence count \(intervals) exceeds \(maximumEvidenceIntervals) five-minute intervals."
            )
        }
        return intervals
    }
}

extension ParameterRecommendation: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, unit, pumpValue, recommendedValue, rawTunedValue
        case changeTier, guardrailStatus, percentChange, isGlucoseDenominated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.unit = try container.decode(String.self, forKey: .unit)
        self.pumpValue = try container.decode(Double.self, forKey: .pumpValue)
        self.recommendedValue = try container.decode(Double.self, forKey: .recommendedValue)
        self.rawTunedValue = try container.decode(Double.self, forKey: .rawTunedValue)
        self.changeTier = try container.decode(ChangeTier.self, forKey: .changeTier)
        self.guardrailStatus = try container.decode(LoopGuardrails.Status.self, forKey: .guardrailStatus)
        self.percentChange = try container.decode(Double.self, forKey: .percentChange)
        self.isGlucoseDenominated = try container.decode(Bool.self, forKey: .isGlucoseDenominated)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(unit, forKey: .unit)
        try container.encode(pumpValue, forKey: .pumpValue)
        try container.encode(recommendedValue, forKey: .recommendedValue)
        try container.encode(rawTunedValue, forKey: .rawTunedValue)
        try container.encode(changeTier, forKey: .changeTier)
        try container.encode(guardrailStatus, forKey: .guardrailStatus)
        try container.encode(percentChange, forKey: .percentChange)
        try container.encode(isGlucoseDenominated, forKey: .isGlucoseDenominated)
    }
}

extension InsufficientEvidence: Codable where Alternative: Codable {
    private enum CodingKeys: String, CodingKey {
        case interpolated, sources
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sources = try container.decode([Int].self, forKey: .sources)
        // Sources are shown as times of day, so each must name one.
        guard sources.count <= 2, sources.allSatisfy({ (0..<86_400).contains($0) }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sources,
                in: container,
                debugDescription: "Interpolation sources must be at most two offsets inside the day."
            )
        }
        let interpolated = try container.decodeIfPresent(Alternative.self, forKey: .interpolated)
        // The note names the sources, so an alternative needs at least one.
        guard interpolated == nil || !sources.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .sources,
                in: container,
                debugDescription: "An interpolated value needs the blocks it came from."
            )
        }
        self.init(interpolated: interpolated, sources: sources)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(interpolated, forKey: .interpolated)
        try container.encode(sources, forKey: .sources)
    }
}

extension ParameterScheduleRecommendation: Codable {
    private enum CodingKeys: String, CodingKey {
        case secondsSinceMidnight, startMinutes
        case parameter, untuned, evidenceCount, daysMissing
        case insufficientEvidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Offsets are range-checked before conversion: a corrupt saved run must
        // fail to decode rather than trap or produce an offset outside the day.
        if let seconds = try container.decodeIfPresent(Int.self, forKey: .secondsSinceMidnight) {
            guard (0..<86_400).contains(seconds) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .secondsSinceMidnight,
                    in: container,
                    debugDescription: "Schedule offset \(seconds) s is outside [0, 86400)."
                )
            }
            self.secondsSinceMidnight = seconds
        } else {
            let minutes = try container.decode(Int.self, forKey: .startMinutes)
            guard (0..<1_440).contains(minutes) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .startMinutes,
                    in: container,
                    debugDescription: "Schedule offset \(minutes) min is outside [0, 1440)."
                )
            }
            self.secondsSinceMidnight = minutes * 60
        }
        self.parameter = try container.decode(ParameterRecommendation.self, forKey: .parameter)
        self.untuned = try container.decode(Bool.self, forKey: .untuned)
        self.evidenceCount = try container.decode(Int.self, forKey: .evidenceCount)
        self.daysMissing = try container.decode(Int.self, forKey: .daysMissing)
        // Absent in runs saved before ADR 0011.
        self.insufficientEvidence = try container.decodeIfPresent(
            InsufficientEvidence<ParameterRecommendation>.self,
            forKey: .insufficientEvidence
        )
        self.untuned = untuned || insufficientEvidence != nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(secondsSinceMidnight, forKey: .secondsSinceMidnight)
        try container.encode(startMinutes, forKey: .startMinutes)
        try container.encode(parameter, forKey: .parameter)
        try container.encode(untuned, forKey: .untuned)
        try container.encode(evidenceCount, forKey: .evidenceCount)
        try container.encode(daysMissing, forKey: .daysMissing)
        try container.encodeIfPresent(insufficientEvidence, forKey: .insufficientEvidence)
    }
}

extension BasalHourRecommendation: Codable {
    private enum CodingKeys: String, CodingKey {
        case hour, pumpRate, recommendedRate, changeTier, guardrailStatus, untuned, daysMissing, sampleCount
        case minimumRate, maximumRate, insufficientEvidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The hour becomes a schedule offset and a table identity when the
        // run is displayed, so it must name an hour of the day.
        let hour = try container.decode(Int.self, forKey: .hour)
        guard (0..<24).contains(hour) else {
            throw DecodingError.dataCorruptedError(
                forKey: .hour,
                in: container,
                debugDescription: "Basal hour \(hour) is outside [0, 24)."
            )
        }
        self.hour = hour
        self.pumpRate = try container.decode(Double.self, forKey: .pumpRate)
        self.recommendedRate = try container.decode(Double.self, forKey: .recommendedRate)
        // The stored changeTier is ignored: older runs classified the unrounded
        // rate, and the tier is now derived from the final rate.
        self.guardrailStatus = try container.decode(LoopGuardrails.Status.self, forKey: .guardrailStatus)
        self.untuned = try container.decode(Bool.self, forKey: .untuned)
        self.daysMissing = try container.decode(Int.self, forKey: .daysMissing)
        self.sampleCount = try container.decodeEvidenceIntervals(forKey: .sampleCount)
        // Runs saved before the limits were stored used the default caps.
        let limits = Self.limits(pumpRate: pumpRate, caps: TuningCaps())
        self.minimumRate = try container.decodeIfPresent(Double.self, forKey: .minimumRate) ?? limits.minimum
        self.maximumRate = try container.decodeIfPresent(Double.self, forKey: .maximumRate) ?? limits.maximum
        // Absent in runs saved before ADR 0011.
        self.insufficientEvidence = try container.decodeIfPresent(
            InsufficientEvidence<Double>.self,
            forKey: .insufficientEvidence
        )
        self.untuned = untuned || insufficientEvidence != nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hour, forKey: .hour)
        try container.encode(pumpRate, forKey: .pumpRate)
        try container.encode(recommendedRate, forKey: .recommendedRate)
        // Kept for readers that still require the key.
        try container.encode(changeTier, forKey: .changeTier)
        try container.encode(guardrailStatus, forKey: .guardrailStatus)
        try container.encode(untuned, forKey: .untuned)
        try container.encode(daysMissing, forKey: .daysMissing)
        try container.encode(sampleCount, forKey: .sampleCount)
        try container.encode(minimumRate, forKey: .minimumRate)
        try container.encode(maximumRate, forKey: .maximumRate)
        try container.encodeIfPresent(insufficientEvidence, forKey: .insufficientEvidence)
    }
}

extension TuningRecommendation: Codable {
    private enum CodingKeys: String, CodingKey {
        case sensitivity, carbRatio, sensitivitySchedule, carbRatioSchedule
        case basalHours, categoryCounts, totalSamples
        case daysAnalyzed, profileGlucoseUnit, daysTuned, settingsChanges
        case excludedOverrideSamples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sensitivity = try container.decode(ParameterRecommendation.self, forKey: .sensitivity)
        let carbRatio = try container.decode(ParameterRecommendation.self, forKey: .carbRatio)
        self.sensitivity = sensitivity
        self.carbRatio = carbRatio
        self.sensitivitySchedule = try container.decodeIfPresent(
            [ParameterScheduleRecommendation].self,
            forKey: .sensitivitySchedule
        ) ?? [ParameterScheduleRecommendation(
            startMinutes: 0,
            parameter: sensitivity,
            untuned: false
        )]
        self.carbRatioSchedule = try container.decodeIfPresent(
            [ParameterScheduleRecommendation].self,
            forKey: .carbRatioSchedule
        ) ?? [ParameterScheduleRecommendation(
            startMinutes: 0,
            parameter: carbRatio,
            untuned: false
        )]
        // Every writer stores one entry for each hour of the day.
        let basalHours = try container.decode([BasalHourRecommendation].self, forKey: .basalHours)
        guard basalHours.count == 24, Set(basalHours.map(\.hour)).count == 24 else {
            throw DecodingError.dataCorruptedError(
                forKey: .basalHours,
                in: container,
                debugDescription: "The basal schedule must hold each hour of the day exactly once."
            )
        }
        self.basalHours = basalHours
        let counts = try container.decode([String: Int].self, forKey: .categoryCounts)
        self.categoryCounts = Dictionary(uniqueKeysWithValues: counts.compactMap { key, value in
            DeviationCategory(rawValue: key).map { ($0, value) }
        })
        self.totalSamples = try container.decodeEvidenceIntervals(forKey: .totalSamples)
        self.daysAnalyzed = try container.decode(Int.self, forKey: .daysAnalyzed)
        self.profileGlucoseUnit = try container.decode(GlucoseUnit.self, forKey: .profileGlucoseUnit)
        self.daysTuned = try container.decodeIfPresent(Int.self, forKey: .daysTuned)
        self.settingsChanges = try container.decodeIfPresent([Date].self, forKey: .settingsChanges) ?? []
        self.excludedOverrideSamples = try container.decodeEvidenceIntervalsIfPresent(
            forKey: .excludedOverrideSamples
        ) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sensitivity, forKey: .sensitivity)
        try container.encode(carbRatio, forKey: .carbRatio)
        try container.encode(sensitivitySchedule, forKey: .sensitivitySchedule)
        try container.encode(carbRatioSchedule, forKey: .carbRatioSchedule)
        try container.encode(basalHours, forKey: .basalHours)
        let counts = Dictionary(uniqueKeysWithValues: categoryCounts.map { ($0.key.rawValue, $0.value) })
        try container.encode(counts, forKey: .categoryCounts)
        try container.encode(totalSamples, forKey: .totalSamples)
        try container.encode(daysAnalyzed, forKey: .daysAnalyzed)
        try container.encode(profileGlucoseUnit, forKey: .profileGlucoseUnit)
        try container.encodeIfPresent(daysTuned, forKey: .daysTuned)
        try container.encode(settingsChanges, forKey: .settingsChanges)
        try container.encode(excludedOverrideSamples, forKey: .excludedOverrideSamples)
    }
}
