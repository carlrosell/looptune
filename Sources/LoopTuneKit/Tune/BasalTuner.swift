import Foundation

/// Tunes the 24-hour basal schedule from basal-categorized deviations, following
/// oref0's per-hour adjustment (deviations at hour h adjust basals at h−3…h−1).
public struct BasalTuner: Sendable {
    let timeZone: TimeZone
    let caps: TuningCaps

    public init(timeZone: TimeZone, caps: TuningCaps = TuningCaps()) {
        self.timeZone = timeZone
        self.caps = caps
    }

    public struct Result: Sendable, Equatable {
        /// Tuned rate per hour (index 0…23).
        public var hourlyRates: [Double]
        /// Whether each hour was left untuned (no data / smoothed from neighbors).
        public var untuned: [Bool]
        /// Basal-categorized deviation samples observed per hour (data coverage).
        public var sampleCounts: [Int]
    }

    /// - Parameters:
    ///   - samples: categorized deviations (only `.basal` are used).
    ///   - currentHourly: current (possibly already-tuned) basal, 24 entries.
    ///   - pumpHourly: fixed pump basal baseline, 24 entries, for caps.
    ///   - isf: the single ISF value used to convert deviations to insulin.
    public func tune(
        samples: [CategorizedSample],
        currentHourly: [Double],
        pumpHourly: [Double],
        isf: Double
    ) -> Result {
        precondition(currentHourly.count == 24 && pumpHourly.count == 24, "hourly arrays must have 24 entries")
        guard isf > 0 else {
            return Result(hourlyRates: currentHourly, untuned: Array(repeating: true, count: 24), sampleCounts: Array(repeating: 0, count: 24))
        }

        // Sum basal-categorized deviations per local hour.
        var deviationsByHour = [Double](repeating: 0, count: 24)
        var countByHour = [Int](repeating: 0, count: 24)
        var evidenceCountByHour = [Int](repeating: 0, count: 24)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        for entry in samples where entry.category == .basal {
            let hour = calendar.component(.hour, from: entry.sample.date)
            deviationsByHour[hour] += entry.sample.deviation
            countByHour[hour] += 1
        }

        var rates = currentHourly
        var touched = [Bool](repeating: false, count: 24)

        // Rounding points below reproduce oref0's autotune/index.js exactly
        // (verified against golden fixtures generated from the real JS): the
        // hourly deviation sum rounds to 3 dp, basalNeeded to 2 dp, and every
        // intermediate rate to 3 dp.
        for hour in 0..<24 {
            guard countByHour[hour] > 0 else { continue }
            let deviationSum = round3(deviationsByHour[hour])
            let basalNeeded = round2(caps.stepFraction * deviationSum / isf)
            let priorHours = [(hour + 21) % 24, (hour + 22) % 24, (hour + 23) % 24] // h−3, h−2, h−1
            for h in priorHours {
                // These samples inform the prior basal hours that are actually
                // adjusted, not the clock hour in which the resulting deviation
                // was observed.
                evidenceCountByHour[h] += countByHour[hour]
            }

            if basalNeeded > 0 {
                let perHour = basalNeeded / 3
                for h in priorHours {
                    rates[h] = round3(rates[h] + perHour)
                    touched[h] = true
                }
            } else if basalNeeded < 0 {
                let threeHourSum = priorHours.reduce(0.0) { $0 + rates[$1] }
                if threeHourSum > 0 {
                    let ratio = 1.0 + basalNeeded / threeHourSum
                    for h in priorHours {
                        rates[h] = round3(rates[h] * ratio)
                        touched[h] = true
                    }
                }
            }
        }

        capRates(&rates, against: pumpHourly)

        // Smooth untouched hours toward the nearest tuned neighbors.
        smoothUntouched(&rates, touched: touched, original: currentHourly)
        // `original` may be a historical profile that lies outside the current
        // pump-relative caps. Smoothing reads that array, so cap again afterward
        // to preserve the safety invariant across settings changes.
        capRates(&rates, against: pumpHourly)

        return Result(hourlyRates: rates.map(round3), untuned: touched.map { !$0 }, sampleCounts: evidenceCountByHour)
    }

    /// oref0's unused-basal smoothing: a forward pass over the hours, where the
    /// "last adjusted" hour defaults to 0 and the "next adjusted" hour defaults
    /// to 23 (no wrap-around), and each smoothed value is read back by later
    /// hours from the live array — quirks preserved for fixture parity.
    private func smoothUntouched(_ rates: inout [Double], touched: [Bool], original: [Double]) {
        for hour in 0..<24 where !touched[hour] {
            var last = 0
            var h = hour - 1
            while h >= 0 {
                if touched[h] { last = h; break }
                h -= 1
            }
            var next = 23
            h = hour + 1
            while h < 24 {
                if touched[h] { next = h; break }
                h += 1
            }
            rates[hour] = round3(0.8 * original[hour] + 0.1 * rates[last] + 0.1 * rates[next])
        }
    }

    private func capRates(_ rates: inout [Double], against pumpHourly: [Double]) {
        for hour in 0..<24 {
            let lower = pumpHourly[hour] * caps.autotuneMin
            let upper = pumpHourly[hour] * caps.autotuneMax
            rates[hour] = round3(TuningMath.clamp(rates[hour], lower, upper))
        }
    }

    private func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
    private func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
