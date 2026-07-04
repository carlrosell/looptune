import Foundation
import LoopAlgorithm

/// A logged carbohydrate entry (Nightscout `Carb Correction`).
public struct CarbRecord: Sendable, Equatable {
    public var date: Date
    public var grams: Double
    /// Entered/estimated absorption time. Loop's default when absent is 3 hours.
    public var absorptionTime: TimeInterval
    public var foodType: String?

    /// Loop's default absorption time when a carb entry omits one.
    public static let defaultAbsorptionTime: TimeInterval = 3 * 3600

    public init(date: Date, grams: Double, absorptionTime: TimeInterval = CarbRecord.defaultAbsorptionTime, foodType: String? = nil) {
        self.date = date
        self.grams = grams
        self.absorptionTime = absorptionTime
        self.foodType = foodType
    }

    public func fixture() -> FixtureCarbEntry {
        FixtureCarbEntry(
            absorptionTime: absorptionTime,
            startDate: date,
            quantity: LoopQuantity(unit: .gram, doubleValue: grams),
            foodType: foodType
        )
    }
}
