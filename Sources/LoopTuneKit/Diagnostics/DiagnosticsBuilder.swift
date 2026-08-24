import Foundation

/// Builds `RunDiagnostics` from a run's inputs and its recommendation.
///
/// The "how it improves" numbers come from replaying the window twice: once
/// with the profile history recorded as active then (before) and once with the
/// recommended settings (after). Deviation is `observed − modeled` glucose change, so
/// a closer in-sample fit produces deviations nearer zero — the same signal the
/// tuner optimizes, surfaced for inspection without claiming future outcomes.
public struct DiagnosticsBuilder: Sendable {
    public init() {}

    public func build(inputs: TuningInputs, recommendation: TuningRecommendation) async throws -> RunDiagnostics {
        let profile = inputs.profile
        let timeZone = profile.timeZone

        // Recommended profile with every tuned time-of-day schedule applied.
        let recommendedProfile = try profile.replacing(
            basalHourly: recommendation.basalHours.sorted { $0.hour < $1.hour }.map { $0.roundedRate() },
            sensitivitySchedule: try recommendation.recommendedSensitivityDailySchedule(),
            carbRatioSchedule: try recommendation.recommendedCarbRatioDailySchedule()
        )

        // The two replays are independent CPU-bound work — run them as
        // concurrent child tasks.
        async let beforeTask = deviations(
            for: profile,
            inputs: inputs,
            useRecordedProfileHistory: true
        )
        async let afterTask = deviations(
            for: recommendedProfile,
            inputs: inputs,
            useRecordedProfileHistory: false
        )
        let (before, after) = await (beforeTask, afterTask)

        let hourly = hourlyDeviations(before: before, after: after, timeZone: timeZone)
        let glucoseInWindow = inputs.glucose.filter {
            $0.date >= inputs.analysisStart && $0.date <= inputs.analysisEnd
        }
        let hourlyGlucose = Self.hourlyDistribution(
            glucoseInWindow.map { (date: $0.date, value: $0.milligramsPerDeciliter) },
            timeZone: timeZone
        )
        let daySummaries = Self.daySummaries(inputs: inputs, timeZone: timeZone)

        return RunDiagnostics(
            glucoseCount: inputs.glucose.count,
            doseCount: inputs.doses.count,
            carbCount: inputs.carbs.count,
            windowStart: inputs.analysisStart,
            windowEnd: inputs.analysisEnd,
            daySummaries: daySummaries,
            hourlyDeviation: hourly,
            meanAbsDeviationBefore: meanAbsolute(before),
            meanAbsDeviationAfter: meanAbsolute(after),
            hourlyGlucose: hourlyGlucose
        )
    }

    /// Replay day-by-day with trimmed inputs and concatenate — the same cost
    /// shape as the chained tuner (linear in days), instead of one full-window
    /// replay whose insulin-effect computation is quadratic in window length.
    private func deviations(
        for profile: TherapyProfile,
        inputs: TuningInputs,
        useRecordedProfileHistory: Bool
    ) -> [DeviationSample] {
        let engine = ReplayEngine()
        let windows = ChainedTuner.dayWindows(
            from: inputs.analysisStart,
            to: inputs.analysisEnd,
            timeZone: profile.timeZone
        )
        var all: [DeviationSample] = []
        for window in windows {
            let segments = useRecordedProfileHistory
                ? ChainedTuner.profileSegments(for: window, history: inputs.profileHistory)
                : [window]
            for segment in segments {
                let segmentProfile = useRecordedProfileHistory
                    ? inputs.profileHistory?.activeProfile(at: segment.start) ?? profile
                    : profile
                let trimmed = ReplayEngine.trimmedInputs(
                    glucose: inputs.glucose,
                    doses: inputs.doses,
                    carbs: inputs.carbs,
                    analysisStart: segment.start,
                    analysisEnd: segment.end
                )
                let samples = (try? engine.computeDeviations(
                    glucose: trimmed.glucose,
                    doses: trimmed.doses,
                    carbs: trimmed.carbs,
                    profile: segmentProfile,
                    analysisStart: segment.start,
                    analysisEnd: segment.end
                )) ?? []
                all += inputs.eligibleDeviations(samples)
            }
        }
        return all
    }

    private func meanAbsolute(_ samples: [DeviationSample]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0) { $0 + abs($1.deviation) } / Double(samples.count)
    }

    private func hourlyDeviations(before: [DeviationSample], after: [DeviationSample], timeZone: TimeZone) -> [HourDeviation] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        func bucket(_ samples: [DeviationSample]) -> (sums: [Double], counts: [Int]) {
            var sums = [Double](repeating: 0, count: 24)
            var counts = [Int](repeating: 0, count: 24)
            for sample in samples {
                let hour = calendar.component(.hour, from: sample.date)
                sums[hour] += sample.deviation
                counts[hour] += 1
            }
            return (sums, counts)
        }

        let beforeBuckets = bucket(before)
        let afterBuckets = bucket(after)

        return (0..<24).map { hour in
            let beforeMean = beforeBuckets.counts[hour] > 0 ? beforeBuckets.sums[hour] / Double(beforeBuckets.counts[hour]) : 0
            let afterMean = afterBuckets.counts[hour] > 0 ? afterBuckets.sums[hour] / Double(afterBuckets.counts[hour]) : 0
            return HourDeviation(hour: hour, before: beforeMean, after: afterMean, sampleCount: beforeBuckets.counts[hour])
        }
    }

    /// Descriptive hourly percentiles use the conventional `(n − 1) × p`
    /// interpolation. This is deliberately separate from oref0's tuning
    /// percentile helper, whose different rank formula is retained for parity.
    static func hourlyDistribution(
        _ values: [(date: Date, value: Double)],
        timeZone: TimeZone
    ) -> [HourlyValueDistribution] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var byHour = [[Double]](repeating: [], count: 24)

        for item in values where item.value.isFinite {
            let hour = calendar.component(.hour, from: item.date)
            byHour[hour].append(item.value)
        }

        return (0..<24).compactMap { hour in
            let sorted = byHour[hour].sorted()
            guard !sorted.isEmpty else { return nil }
            return HourlyValueDistribution(
                hour: hour,
                sampleCount: sorted.count,
                p10: descriptivePercentile(sorted, 0.10),
                p25: descriptivePercentile(sorted, 0.25),
                median: descriptivePercentile(sorted, 0.50),
                p75: descriptivePercentile(sorted, 0.75),
                p90: descriptivePercentile(sorted, 0.90)
            )
        }
    }

    private static func descriptivePercentile(_ sorted: [Double], _ percentile: Double) -> Double {
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }
        let rank = Double(sorted.count - 1) * percentile
        let lower = Int(rank.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        let fraction = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    static func daySummaries(inputs: TuningInputs, timeZone: TimeZone) -> [DaySummary] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        func dayKey(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }

        struct Accumulator {
            var glucose: [Double] = []
            var bolusCount = 0
            var automaticBolusCount = 0
            var totalBolus = 0.0
            var tempBasalCount = 0
            var carbCount = 0
            var totalCarbs = 0.0
        }

        var byDay: [String: Accumulator] = [:]
        let window = inputs.analysisStart...inputs.analysisEnd

        for sample in inputs.glucose where window.contains(sample.date) {
            byDay[dayKey(sample.date), default: Accumulator()].glucose.append(sample.milligramsPerDeciliter)
        }
        for dose in inputs.doses where window.contains(dose.startDate) {
            let key = dayKey(dose.startDate)
            switch dose.kind {
            case .bolus(let units):
                byDay[key, default: Accumulator()].bolusCount += 1
                byDay[key, default: Accumulator()].totalBolus += units
                if dose.automatic { byDay[key, default: Accumulator()].automaticBolusCount += 1 }
            case .tempBasal, .suspend:
                byDay[key, default: Accumulator()].tempBasalCount += 1
            }
        }
        for carb in inputs.carbs where window.contains(carb.date) {
            let key = dayKey(carb.date)
            byDay[key, default: Accumulator()].carbCount += 1
            byDay[key, default: Accumulator()].totalCarbs += carb.grams
        }

        return byDay.keys.sorted().map { key in
            let acc = byDay[key]!
            let count = acc.glucose.count
            let mean = count > 0 ? acc.glucose.reduce(0, +) / Double(count) : 0
            let inRange = acc.glucose.filter { $0 >= 70 && $0 <= 180 }.count
            let tir = count > 0 ? Double(inRange) / Double(count) * 100 : 0
            return DaySummary(
                date: key,
                glucoseCount: count,
                meanGlucose: mean,
                timeInRangePercent: tir,
                bolusCount: acc.bolusCount,
                automaticBolusCount: acc.automaticBolusCount,
                totalBolusInsulin: acc.totalBolus,
                tempBasalCount: acc.tempBasalCount,
                carbCount: acc.carbCount,
                totalCarbs: acc.totalCarbs
            )
        }
    }
}
