import Foundation

// Codable conformances so a full recommendation can be persisted and reloaded
// (the run history). Values are stored verbatim rather than recomputed, so a
// reloaded run renders identically to when it was produced.

extension ChangeTier: Codable {}
extension LoopGuardrails.Status: Codable {}
extension DeviationCategory: Codable {}

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

extension ParameterScheduleRecommendation: Codable {
    private enum CodingKeys: String, CodingKey {
        case secondsSinceMidnight, startMinutes
        case parameter, untuned, evidenceCount, daysMissing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let seconds = try container.decodeIfPresent(Int.self, forKey: .secondsSinceMidnight) {
            self.secondsSinceMidnight = seconds
        } else {
            self.secondsSinceMidnight = try container.decode(Int.self, forKey: .startMinutes) * 60
        }
        self.parameter = try container.decode(ParameterRecommendation.self, forKey: .parameter)
        self.untuned = try container.decode(Bool.self, forKey: .untuned)
        self.evidenceCount = try container.decode(Int.self, forKey: .evidenceCount)
        self.daysMissing = try container.decode(Int.self, forKey: .daysMissing)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(secondsSinceMidnight, forKey: .secondsSinceMidnight)
        try container.encode(startMinutes, forKey: .startMinutes)
        try container.encode(parameter, forKey: .parameter)
        try container.encode(untuned, forKey: .untuned)
        try container.encode(evidenceCount, forKey: .evidenceCount)
        try container.encode(daysMissing, forKey: .daysMissing)
    }
}

extension BasalHourRecommendation: Codable {
    private enum CodingKeys: String, CodingKey {
        case hour, pumpRate, recommendedRate, changeTier, guardrailStatus, untuned, daysMissing, sampleCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hour = try container.decode(Int.self, forKey: .hour)
        self.pumpRate = try container.decode(Double.self, forKey: .pumpRate)
        self.recommendedRate = try container.decode(Double.self, forKey: .recommendedRate)
        self.changeTier = try container.decode(ChangeTier.self, forKey: .changeTier)
        self.guardrailStatus = try container.decode(LoopGuardrails.Status.self, forKey: .guardrailStatus)
        self.untuned = try container.decode(Bool.self, forKey: .untuned)
        self.daysMissing = try container.decode(Int.self, forKey: .daysMissing)
        self.sampleCount = try container.decode(Int.self, forKey: .sampleCount)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hour, forKey: .hour)
        try container.encode(pumpRate, forKey: .pumpRate)
        try container.encode(recommendedRate, forKey: .recommendedRate)
        try container.encode(changeTier, forKey: .changeTier)
        try container.encode(guardrailStatus, forKey: .guardrailStatus)
        try container.encode(untuned, forKey: .untuned)
        try container.encode(daysMissing, forKey: .daysMissing)
        try container.encode(sampleCount, forKey: .sampleCount)
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
        self.basalHours = try container.decode([BasalHourRecommendation].self, forKey: .basalHours)
        let counts = try container.decode([String: Int].self, forKey: .categoryCounts)
        self.categoryCounts = Dictionary(uniqueKeysWithValues: counts.compactMap { key, value in
            DeviationCategory(rawValue: key).map { ($0, value) }
        })
        self.totalSamples = try container.decode(Int.self, forKey: .totalSamples)
        self.daysAnalyzed = try container.decode(Int.self, forKey: .daysAnalyzed)
        self.profileGlucoseUnit = try container.decode(GlucoseUnit.self, forKey: .profileGlucoseUnit)
        self.daysTuned = try container.decodeIfPresent(Int.self, forKey: .daysTuned)
        self.settingsChanges = try container.decodeIfPresent([Date].self, forKey: .settingsChanges) ?? []
        self.excludedOverrideSamples = try container.decodeIfPresent(
            Int.self,
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
