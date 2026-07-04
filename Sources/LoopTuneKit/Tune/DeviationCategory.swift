import Foundation

/// How a 5-minute deviation datum is attributed, following oref0's autotune
/// categorization (adapted to Loop-native deviations).
public enum DeviationCategory: String, Sendable, Equatable {
    /// Carb absorption (meal) — informs carb-ratio tuning.
    case csf
    /// Unannounced-meal / unexplained rise. Loop has no UAM, so these are
    /// reassigned (default: to basal) before tuning.
    case uam
    /// Attributable to scheduled basal — informs per-hour basal tuning.
    case basal
    /// Attributable to insulin sensitivity — informs ISF tuning.
    case isf
}

/// A deviation datum plus its category and the scheduled values in force at its
/// timestamp.
public struct CategorizedSample: Sendable, Equatable {
    public var sample: DeviationSample
    public var category: DeviationCategory
    /// Scheduled basal rate (U/hr) at the sample time.
    public var scheduledBasal: Double
    /// Scheduled ISF (mg/dL/U) at the sample time.
    public var scheduledISF: Double
    /// Carbs (g) attributed to the active meal, when categorized CSF.
    public var mealCarbs: Double

    public init(
        sample: DeviationSample,
        category: DeviationCategory,
        scheduledBasal: Double,
        scheduledISF: Double,
        mealCarbs: Double = 0
    ) {
        self.sample = sample
        self.category = category
        self.scheduledBasal = scheduledBasal
        self.scheduledISF = scheduledISF
        self.mealCarbs = mealCarbs
    }
}
