import Foundation

/// How large a recommended change is, using AutotuneWeb's highlight thresholds.
public enum ChangeTier: String, Sendable, Equatable {
    /// < 10% change.
    case minimal
    /// ≥ 10% change (worth attention).
    case notable
    /// ≥ +20% or ≤ −30% change (autotune's own caps — review carefully).
    case large

    public static func classify(pump: Double, tuned: Double) -> ChangeTier {
        guard pump != 0 else { return tuned == 0 ? .minimal : .large }
        let change = (tuned - pump) / pump
        if change >= 0.20 || change <= -0.30 { return .large }
        if abs(change) >= 0.10 { return .notable }
        return .minimal
    }
}

/// A single tunable parameter's recommendation.
public struct ParameterRecommendation: Sendable, Equatable {
    public var name: String
    public var unit: String
    public var pumpValue: Double
    /// The tuned value after guardrail clamping.
    public var recommendedValue: Double
    /// The raw tuned value before guardrail clamping.
    public var rawTunedValue: Double
    public var changeTier: ChangeTier
    public var guardrailStatus: LoopGuardrails.Status
    /// Percent change from pump to recommended (signed).
    public var percentChange: Double

    public init(name: String, unit: String, pumpValue: Double, rawTunedValue: Double, bounds: LoopGuardrails.Bounds) {
        self.name = name
        self.unit = unit
        self.pumpValue = pumpValue
        self.rawTunedValue = rawTunedValue
        let clamped = LoopGuardrails.clamp(rawTunedValue, to: bounds)
        self.recommendedValue = clamped.value
        self.guardrailStatus = clamped.status
        self.changeTier = ChangeTier.classify(pump: pumpValue, tuned: clamped.value)
        self.percentChange = pumpValue == 0 ? 0 : (clamped.value - pumpValue) / pumpValue * 100
    }
}

/// One tuned basal hour.
public struct BasalHourRecommendation: Sendable, Equatable {
    public var hour: Int
    public var pumpRate: Double
    public var recommendedRate: Double
    public var changeTier: ChangeTier
    public var guardrailStatus: LoopGuardrails.Status
    public var untuned: Bool

    public init(hour: Int, pumpRate: Double, rawTunedRate: Double, untuned: Bool) {
        self.hour = hour
        self.pumpRate = pumpRate
        let clamped = LoopGuardrails.clamp(rawTunedRate, to: LoopGuardrails.basalRate)
        self.recommendedRate = clamped.value
        self.changeTier = ChangeTier.classify(pump: pumpRate, tuned: clamped.value)
        self.guardrailStatus = clamped.status
        self.untuned = untuned
    }
}

/// The full tuning recommendation, ready for presentation.
public struct TuningRecommendation: Sendable, Equatable {
    public var sensitivity: ParameterRecommendation
    public var carbRatio: ParameterRecommendation
    public var basalHours: [BasalHourRecommendation]

    /// Category counts and sample totals for confidence context.
    public var categoryCounts: [DeviationCategory: Int]
    public var totalSamples: Int
    public var daysAnalyzed: Int

    /// Sum of tuned basal over 24 hours (daily total, U).
    public var tunedDailyBasal: Double { basalHours.reduce(0) { $0 + $1.recommendedRate } }
    public var pumpDailyBasal: Double { basalHours.reduce(0) { $0 + $1.pumpRate } }

    public init(from output: TuningOutput, daysAnalyzed: Int) {
        precondition(
            output.tunedBasalHourly.count == 24 && output.pumpBasalHourly.count == 24 && output.untunedBasalHours.count == 24,
            "TuningOutput basal arrays must each contain 24 hourly entries"
        )
        self.sensitivity = ParameterRecommendation(
            name: "Insulin Sensitivity",
            unit: "mg/dL/U",
            pumpValue: output.pumpISF,
            rawTunedValue: output.tunedISF,
            bounds: LoopGuardrails.sensitivity
        )
        self.carbRatio = ParameterRecommendation(
            name: "Carb Ratio",
            unit: "g/U",
            pumpValue: output.pumpCarbRatio,
            rawTunedValue: output.tunedCarbRatio,
            bounds: LoopGuardrails.carbRatio
        )
        self.basalHours = (0..<24).map { hour in
            BasalHourRecommendation(
                hour: hour,
                pumpRate: output.pumpBasalHourly[hour],
                rawTunedRate: output.tunedBasalHourly[hour],
                untuned: output.untunedBasalHours[hour]
            )
        }
        self.categoryCounts = output.categoryCounts
        self.totalSamples = output.totalSamples
        self.daysAnalyzed = daysAnalyzed
    }
}
