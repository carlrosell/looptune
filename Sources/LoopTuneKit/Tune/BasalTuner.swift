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
            return Result(hourlyRates: currentHourly, untuned: Array(repeating: true, count: 24))
        }

        // Sum basal-categorized deviations per local hour.
        var deviationsByHour = [Double](repeating: 0, count: 24)
        var countByHour = [Int](repeating: 0, count: 24)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        for entry in samples where entry.category == .basal {
            let hour = calendar.component(.hour, from: entry.sample.date)
            deviationsByHour[hour] += entry.sample.deviation
            countByHour[hour] += 1
        }

        var rates = currentHourly
        var touched = [Bool](repeating: false, count: 24)

        for hour in 0..<24 {
            guard countByHour[hour] > 0 else { continue }
            let basalNeeded = caps.stepFraction * deviationsByHour[hour] / isf
            let priorHours = [(hour + 21) % 24, (hour + 22) % 24, (hour + 23) % 24] // h−3, h−2, h−1

            if basalNeeded > 0 {
                let perHour = basalNeeded / 3
                for h in priorHours {
                    rates[h] += perHour
                    touched[h] = true
                }
            } else if basalNeeded < 0 {
                let threeHourSum = priorHours.reduce(0.0) { $0 + rates[$1] }
                if threeHourSum > 0 {
                    let ratio = 1.0 + basalNeeded / threeHourSum
                    for h in priorHours {
                        rates[h] *= ratio
                        touched[h] = true
                    }
                }
            }
        }

        // Cap each hour vs the pump baseline.
        for hour in 0..<24 {
            let lower = pumpHourly[hour] * caps.autotuneMin
            let upper = pumpHourly[hour] * caps.autotuneMax
            rates[hour] = TuningMath.clamp(rates[hour], lower, upper)
        }

        // Smooth untouched hours toward the nearest tuned neighbors.
        smoothUntouched(&rates, touched: touched, original: currentHourly)

        return Result(hourlyRates: rates.map { ($0 * 1000).rounded() / 1000 }, untuned: touched.map { !$0 })
    }

    private func smoothUntouched(_ rates: inout [Double], touched: [Bool], original: [Double]) {
        for hour in 0..<24 where !touched[hour] {
            let last = nearestTouched(from: hour, step: -1, touched: touched) ?? hour
            let next = nearestTouched(from: hour, step: +1, touched: touched) ?? hour
            rates[hour] = 0.8 * original[hour] + 0.1 * rates[last] + 0.1 * rates[next]
        }
    }

    private func nearestTouched(from hour: Int, step: Int, touched: [Bool]) -> Int? {
        var h = hour
        for _ in 0..<23 {
            h = (h + step + 24) % 24
            if touched[h] { return h }
        }
        return nil
    }
}
