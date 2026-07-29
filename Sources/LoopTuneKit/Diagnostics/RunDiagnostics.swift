import Foundation

/// A per-local-day summary of the data that was ingested for a run — the
/// "what went in" view.
public struct DaySummary: Codable, Sendable, Equatable, Identifiable {
    public var date: String            // yyyy-MM-dd (profile-local)
    public var glucoseCount: Int
    public var meanGlucose: Double     // mg/dL
    public var timeInRangePercent: Double  // 70–180 mg/dL
    public var bolusCount: Int
    public var automaticBolusCount: Int
    public var totalBolusInsulin: Double
    public var tempBasalCount: Int
    public var carbCount: Int
    public var totalCarbs: Double

    public var id: String { date }

    public init(date: String, glucoseCount: Int, meanGlucose: Double, timeInRangePercent: Double, bolusCount: Int, automaticBolusCount: Int, totalBolusInsulin: Double, tempBasalCount: Int, carbCount: Int, totalCarbs: Double) {
        self.date = date
        self.glucoseCount = glucoseCount
        self.meanGlucose = meanGlucose
        self.timeInRangePercent = timeInRangePercent
        self.bolusCount = bolusCount
        self.automaticBolusCount = automaticBolusCount
        self.totalBolusInsulin = totalBolusInsulin
        self.tempBasalCount = tempBasalCount
        self.carbCount = carbCount
        self.totalCarbs = totalCarbs
    }
}

/// Per-hour glucose deviation under the recorded settings vs the recommended
/// settings — the "what's wrong and how it changes" view. Deviation is
/// `observed − modeled` glucose change (mg/dL); values far from zero mean the
/// model does not fit what actually happened at that hour.
public struct HourDeviation: Codable, Sendable, Equatable, Identifiable {
    public var hour: Int
    /// Mean deviation under the settings recorded as active then (mg/dL).
    public var before: Double
    /// Mean deviation if the recommended settings had been used (mg/dL).
    public var after: Double
    /// Deviation samples behind this hour.
    public var sampleCount: Int

    public var id: Int { hour }

    /// Whether this hour's current mean deviation is large enough to flag.
    public var isProblem: Bool { abs(before) >= HourDeviation.problemThreshold }
    /// Whether the recommendation meaningfully reduces this hour's deviation.
    public var improves: Bool { abs(after) < abs(before) - 0.5 }

    /// mg/dL per 5-min interval that counts as a meaningful bias.
    public static let problemThreshold: Double = 2.0

    public init(hour: Int, before: Double, after: Double, sampleCount: Int) {
        self.hour = hour
        self.before = before
        self.after = after
        self.sampleCount = sampleCount
    }
}

/// Everything shown on a run's detail view: what was ingested, what the
/// algorithm thinks is off, and how the recommendation would change it.
public struct RunDiagnostics: Codable, Sendable, Equatable {
    public var glucoseCount: Int
    public var doseCount: Int
    public var carbCount: Int
    public var windowStart: Date
    public var windowEnd: Date

    public var daySummaries: [DaySummary]
    public var hourlyDeviation: [HourDeviation]

    /// Mean absolute deviation across the window (mg/dL) — the headline quality
    /// number. Lower is a closer fit to this same historical replay; it is an
    /// in-sample diagnostic, not evidence of future glucose outcomes.
    public var meanAbsDeviationBefore: Double
    public var meanAbsDeviationAfter: Double

    public var improvementPercent: Double {
        guard meanAbsDeviationBefore > 0 else { return 0 }
        return (meanAbsDeviationBefore - meanAbsDeviationAfter) / meanAbsDeviationBefore * 100
    }

    /// Hours flagged as running off under the settings recorded at the time.
    public var problemHours: [HourDeviation] { hourlyDeviation.filter(\.isProblem) }

    public init(glucoseCount: Int, doseCount: Int, carbCount: Int, windowStart: Date, windowEnd: Date, daySummaries: [DaySummary], hourlyDeviation: [HourDeviation], meanAbsDeviationBefore: Double, meanAbsDeviationAfter: Double) {
        self.glucoseCount = glucoseCount
        self.doseCount = doseCount
        self.carbCount = carbCount
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.daySummaries = daySummaries
        self.hourlyDeviation = hourlyDeviation
        self.meanAbsDeviationBefore = meanAbsDeviationBefore
        self.meanAbsDeviationAfter = meanAbsDeviationAfter
    }
}
