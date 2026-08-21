import Foundation

extension SensitivityTuner {
    /// Tune each ISF block already configured in the pump profile. Keeping the
    /// pump's boundaries avoids inventing new time-of-day settings from sparse
    /// retrospective data.
    func tuneSchedule(
        samples: [CategorizedSample],
        currentSchedule: DailySchedule<Double>,
        pumpSchedule: DailySchedule<Double>,
        timeZone: TimeZone
    ) -> [ScheduleTuningOutput] {
        let grouped = Dictionary(grouping: samples.filter { $0.category == .isf }) { entry in
            ScheduleSlot.index(
                for: entry.sample.date,
                entries: pumpSchedule.entries,
                timeZone: timeZone
            )
        }

        return pumpSchedule.entries.enumerated().map { index, pumpEntry in
            let currentISF = currentSchedule.value(atSecondsSinceMidnight: pumpEntry.secondsSinceMidnight)
            let result = tuneWithEvidence(
                samples: grouped[index] ?? [],
                currentISF: currentISF,
                pumpISF: pumpEntry.value
            )
            return ScheduleTuningOutput(
                secondsSinceMidnight: pumpEntry.secondsSinceMidnight,
                tunedValue: result.value,
                pumpValue: pumpEntry.value,
                untuned: result.untuned,
                evidenceCount: result.usableSampleCount
            )
        }
    }
}

extension CarbRatioTuner {
    /// Tune each carb-ratio block already configured in the pump profile.
    /// Meal residuals follow the most recent logged meal, so absorption that
    /// crosses a schedule boundary stays with the ratio active when the meal
    /// was entered.
    func tuneSchedule(
        samples: [CategorizedSample],
        carbs: [CarbRecord],
        currentProfile: TherapyProfile,
        pumpSchedule: DailySchedule<Double>,
        tunedSensitivity: [ScheduleTuningOutput]
    ) -> [ScheduleTuningOutput] {
        let timeZone = currentProfile.timeZone
        let sortedCarbs = carbs.sorted { $0.date < $1.date }
        var carbsBySlot = [[CarbRecord]](repeating: [], count: pumpSchedule.entries.count)
        for carb in sortedCarbs {
            let slot = ScheduleSlot.index(for: carb.date, entries: pumpSchedule.entries, timeZone: timeZone)
            carbsBySlot[slot].append(carb)
        }

        var deviationsBySlot = [Double](repeating: 0, count: pumpSchedule.entries.count)
        let csfSamples = samples.filter { $0.category == .csf }.sorted { $0.sample.date < $1.sample.date }
        if pumpSchedule.entries.count == 1 {
            // Preserve the original whole-day calculation exactly for flat CR
            // profiles, including meal absorption that began before a segment.
            deviationsBySlot[0] = csfSamples.reduce(0) { $0 + $1.sample.deviation }
        } else {
            var latestCarbIndex = -1
            for entry in csfSamples {
                while latestCarbIndex + 1 < sortedCarbs.count,
                      sortedCarbs[latestCarbIndex + 1].date <= entry.sample.date {
                    latestCarbIndex += 1
                }
                guard latestCarbIndex >= 0 else { continue }
                let meal = sortedCarbs[latestCarbIndex]
                guard entry.sample.date.timeIntervalSince(meal.date) <= ReplayEngine.carbLookback else {
                    continue
                }
                let slot = ScheduleSlot.index(for: meal.date, entries: pumpSchedule.entries, timeZone: timeZone)
                deviationsBySlot[slot] += entry.sample.deviation
            }
        }

        return pumpSchedule.entries.enumerated().map { index, pumpEntry in
            let meals = carbsBySlot[index]
            let totalCarbs = meals.reduce(0.0) { $0 + $1.grams }
            let fallbackCurrentCR = currentProfile.carbRatioSchedule.value(
                atSecondsSinceMidnight: pumpEntry.secondsSinceMidnight
            )
            guard totalCarbs > 0 else {
                return ScheduleTuningOutput(
                    secondsSinceMidnight: pumpEntry.secondsSinceMidnight,
                    tunedValue: fallbackCurrentCR,
                    pumpValue: pumpEntry.value,
                    untuned: true
                )
            }

            var replayCSFTotal = 0.0
            var targetISFTotal = 0.0
            var currentCRTotal = 0.0
            for meal in meals {
                let currentISF = currentProfile.sensitivitySchedule.value(at: meal.date, timeZone: timeZone)
                let currentCR = currentProfile.carbRatioSchedule.value(at: meal.date, timeZone: timeZone)
                let targetISF = ScheduleSlot.value(
                    at: meal.date,
                    in: tunedSensitivity,
                    timeZone: timeZone
                )
                replayCSFTotal += meal.grams * currentISF / currentCR
                targetISFTotal += meal.grams * targetISF
                currentCRTotal += meal.grams * currentCR
            }

            let currentCR = currentCRTotal / totalCarbs
            let replayCSF = replayCSFTotal / totalCarbs
            let targetISF = targetISFTotal / totalCarbs
            // The scalar tuner consumes replayISF/currentCR. Reconstructing an
            // equivalent replayISF lets it retain its caps, stepping, and
            // fixture-pinned behavior while using the meal-weighted CSF.
            let result = tuneWithEvidence(
                mealDeviations: deviationsBySlot[index],
                totalMealCarbs: totalCarbs,
                replayISF: replayCSF * currentCR,
                targetISF: targetISF,
                currentCR: currentCR,
                pumpCR: pumpEntry.value
            )
            return ScheduleTuningOutput(
                secondsSinceMidnight: pumpEntry.secondsSinceMidnight,
                tunedValue: result.value,
                pumpValue: pumpEntry.value,
                untuned: result.untuned,
                evidenceCount: meals.count
            )
        }
    }
}

private enum ScheduleSlot {
    static func index(
        for date: Date,
        entries: [DailySchedule<Double>.Entry],
        timeZone: TimeZone
    ) -> Int {
        let seconds = DailySchedule<Double>.secondsSinceMidnight(of: date, in: timeZone)
        var result = 0
        for index in entries.indices where entries[index].secondsSinceMidnight <= seconds {
            result = index
        }
        return result
    }

    static func value(
        at date: Date,
        in entries: [ScheduleTuningOutput],
        timeZone: TimeZone
    ) -> Double {
        let seconds = DailySchedule<Double>.secondsSinceMidnight(of: date, in: timeZone)
        var result = entries[0].tunedValue
        for entry in entries where entry.secondsSinceMidnight <= seconds {
            result = entry.tunedValue
        }
        return result
    }
}
