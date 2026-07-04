import Foundation

/// Loop's therapy-setting guardrails (from LoopKit's `Guardrail+Settings.swift`,
/// via the research notes). A recommendation is clamped to the absolute range
/// and flagged when it falls outside the recommended range.
public enum LoopGuardrails {
    public struct Bounds: Sendable, Equatable {
        public var absoluteMin: Double
        public var absoluteMax: Double
        public var recommendedMin: Double
        public var recommendedMax: Double
    }

    /// Insulin sensitivity factor, mg/dL/U.
    public static let sensitivity = Bounds(absoluteMin: 10, absoluteMax: 500, recommendedMin: 16, recommendedMax: 399)
    /// Carb ratio, g/U.
    public static let carbRatio = Bounds(absoluteMin: 2, absoluteMax: 150, recommendedMin: 4, recommendedMax: 28)
    /// Scheduled basal rate, U/hr (upper bound is also pump-limited).
    public static let basalRate = Bounds(absoluteMin: 0.05, absoluteMax: 30, recommendedMin: 0.05, recommendedMax: 30)

    /// Where a value sits relative to a guardrail.
    public enum Status: String, Sendable, Equatable {
        /// Within the recommended range.
        case ok
        /// Outside the recommended range but within absolute limits.
        case outsideRecommended
        /// At (clamped to) an absolute limit.
        case atLimit
    }

    /// Clamp `value` to the absolute range and report where it landed.
    public static func clamp(_ value: Double, to bounds: Bounds) -> (value: Double, status: Status) {
        if value < bounds.absoluteMin {
            return (bounds.absoluteMin, .atLimit)
        }
        if value > bounds.absoluteMax {
            return (bounds.absoluteMax, .atLimit)
        }
        if value < bounds.recommendedMin || value > bounds.recommendedMax {
            return (value, .outsideRecommended)
        }
        return (value, .ok)
    }
}
