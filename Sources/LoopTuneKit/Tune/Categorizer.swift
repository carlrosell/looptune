import Foundation

/// Options controlling how deviations are categorized.
public struct CategorizerOptions: Sendable, Equatable {
    /// Treat all UAM (unannounced-meal) data as basal. Loop has no UAM, so this
    /// defaults to `true` (matching nighttune's default for full-closed-loop use).
    public var categorizeUAMAsBasal: Bool

    public init(categorizeUAMAsBasal: Bool = true) {
        self.categorizeUAMAsBasal = categorizeUAMAsBasal
    }
}

/// Assigns each deviation datum a category (CSF/UAM/basal/ISF), following
/// oref0's `categorize.js` decision logic, using Loop-native deviations and
/// LoopAlgorithm's dynamic carbs-on-board for meal detection.
public struct Categorizer: Sendable {
    let profile: TherapyProfile
    let options: CategorizerOptions

    public init(profile: TherapyProfile, options: CategorizerOptions = CategorizerOptions()) {
        self.profile = profile
        self.options = options
    }

    /// Reset the stateful absorbing/UAM flags across a CGM gap larger than this
    /// (the replay omits gapped intervals, breaking physiological continuity).
    static let stateResetGap: TimeInterval = 20 * 60

    public func categorize(_ samples: [DeviationSample]) -> [CategorizedSample] {
        var absorbing = false
        var uam = false
        var previousDate: Date?
        var result: [CategorizedSample] = []

        for sample in samples {
            if let previousDate, sample.date.timeIntervalSince(previousDate) > Self.stateResetGap {
                absorbing = false
                uam = false
            }
            previousDate = sample.date
            let scheduledBasal = profile.basalSchedule.value(at: sample.date, timeZone: profile.timeZone)
            let scheduledISF = profile.sensitivitySchedule.value(at: sample.date, timeZone: profile.timeZone)
            // Insulin activity contribution attributable to scheduled basal.
            let basalBGI = scheduledBasal * scheduledISF / 60 * 5
            let bgi = sample.insulinEffect
            let deviation = sample.deviation
            let category: DeviationCategory

            if sample.carbsOnBoard > 0 || absorbing {
                // Meal / carb absorption.
                if sample.insulinOnBoard < scheduledBasal / 2 {
                    absorbing = false
                } else {
                    absorbing = deviation > 0
                }
                category = .csf
            } else if sample.insulinOnBoard > 2 * scheduledBasal || deviation > 6 || uam {
                uam = deviation > 0
                category = .uam
            } else {
                // basal vs ISF
                if basalBGI > -4 * bgi {
                    category = .basal
                } else if sample.averageDelta > 0 && sample.averageDelta > -2 * bgi {
                    category = .basal
                } else {
                    category = .isf
                }
            }

            result.append(CategorizedSample(
                sample: sample,
                category: category,
                scheduledBasal: scheduledBasal,
                scheduledISF: scheduledISF,
                mealCarbs: category == .csf ? sample.carbsOnBoard : 0
            ))
        }

        return applyUAMReassignment(result)
    }

    /// Reassign UAM data. Loop has no UAM; the default policy folds it into
    /// basal. (oref0's more elaborate lowest-50%-deviation retention is a future
    /// option — see OQ-3.)
    private func applyUAMReassignment(_ samples: [CategorizedSample]) -> [CategorizedSample] {
        guard options.categorizeUAMAsBasal else { return samples }
        return samples.map { sample in
            guard sample.category == .uam else { return sample }
            var reassigned = sample
            reassigned.category = .basal
            return reassigned
        }
    }
}
