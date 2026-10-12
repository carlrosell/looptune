# 0008. Bound carb absorption time and derive replay retention from it

- **Status:** Proposed
- **Date:** 2026-10-12
- **Deciders:** Project owner
- **Related:** [#18](https://github.com/carlrosell/looptune/issues/18) (CORE-07), [Repository audit](../docs/code-reviews/2026-10-12-repository-audit-review.md#core-07-fixed-carb-lookback-drops-meals-still-active-in-the-model), [ADR 0004](0004-historical-replay-context.md), [#11](https://github.com/carlrosell/looptune/issues/11) (DATA-04)

## Context

`ReplayEngine.trimmedInputs` kept carbs and glucose for ten hours before each
replayed segment and doses for eighteen. The ten hours came from
`CarbMath.maximumAbsorptionTimeInterval`, but the pinned LoopAlgorithm model
does not clamp to that constant on the path replay uses. A meal stays active
until `start + 1.5 × absorptionTime + 10 min` (`CarbStatusBuilder.maxEndDate`).
When observed absorption falls below the modeled minimum, the model spreads the
remainder over a span that already includes the delay, so the effect can end
one delay later. Nothing bounded the entered absorption time.

A 60 g meal with an eight-hour absorption time, logged 10.5 hours before a
segment, still had 1.547497 g on board and a deviation of -0.668724 at the
segment's first sample in full replay. Trimming dropped the meal and returned
zero for both.

The model also splits observed absorption among every meal active at a given
time. Dropping an earlier meal that overlapped a retained one changes the
retained meal's absorption, even when the earlier meal ends before the segment.

## Decision

Replay supports entered absorption times up to
`CarbRecord.maximumAbsorptionTime`, which equals
`CarbMath.maximumAbsorptionTimeInterval` (10 hours). `TuningPipeline` rejects
longer entries with `PipelineError.unsupportedCarbAbsorption`, which carries the
earliest offending entry's date, grams, and absorption time and the profile's
time zone. Its description names that entry in the profile's time zone, states
the 10-hour limit, and tells the user to edit the entry or choose a window that
starts at least two days after it. The app and CLI show that text. `HistoricalReplay`
throws `ReplayError.unsupportedAbsorptionTime(date)`, so `ChainedTuner` and
`DiagnosticsBuilder` fail explicitly when called directly. They do not drop or
clamp the meal.

Retention comes from that bound:

- `carbLookback` is the longest modeled span, `1.5 × 10 h + 10 min`, plus a
  35-minute margin: one more effect delay for the minimum-rate tail, the
  20-minute maximum CGM gap that the first sample's interval can reach back
  over, and one five-minute effect grid step. That gives 15h45m. Every meal
  still active in a segment starts inside it.
- Every meal inside `carbLookback` is kept, not only meals that reach the
  segment. That keeps earlier meals that overlapped an active one inside the
  span.
- `glucoseLookback` equals `carbLookback`, so the earliest retained meal has
  counteraction effects from its start.
- `doseLookback` is `glucoseLookback + 8 h` (23h45m). Counteraction effects
  need the insulin effect at every retained glucose sample. Doses act for
  6h10m, and the remaining 1h50m covers a dose still being delivered at the
  cutoff. This keeps the eight-hour allowance the earlier 18h/10h split had.
- `inputLookback`, `max(doseLookback, carbLookback, glucoseLookback)`, is
  therefore 23h45m. It bounds every input replay reads and is what DATA-04
  uses to size data and profile fetching.

The carb-ratio tuner's meal attribution window stays at ten hours as its own
constant, `CarbRatioTuner.mealAttributionWindow`. It is an attribution
heuristic, and this decision does not change it.

## Alternatives considered

- **Per-meal retention from each meal's own span.** A meal reaches a segment
  only if `start + span + margin` passes the segment start. Exact equivalence
  also needs every earlier meal that overlaps a retained one, repeated until
  nothing new is added. With continuous overlapping meals this chain reaches
  the start of the data and makes chained replay quadratic again. Any cap on
  the chain gives the same result as a fixed lookback, which is simpler.
- **Clamp long absorption times to 10 hours.** This would replay a different
  meal than the one entered, without saying so.
- **Retain everything.** Exact, but each day's replay would cost the whole
  window.
- **Change the dependency or its overrun.** Out of scope; the pinned revision
  is a constraint.

## Consequences

Trimmed replay equals full replay for every supported meal that is active in
the segment, and for earlier meals that overlapped it inside `carbLookback`. A
meal that began before `carbLookback` is dropped even if it overlapped a
retained meal. The retained meal is then attributed that shared absorption
alone. Such a meal cannot itself be active in the segment.

A Nightscout carb entry with an absorption time over 10 hours now fails the
run instead of being partly dropped. The fetch reads whole UTC days from up to
48 hours before the window, so such an entry blocks a run until it is edited or
falls outside that lead-in.

Each replay reads up to 23h45m before its segment instead of 18 hours. This is
still within the one lead-in day the current fetch uses. Under ADR 0004,
`TuningPipeline` takes the chained path when a therapy change falls inside the
window or within `inputLookback` before it, so that window grows from 18 hours
to 23h45m. Profile history needs to reach the same distance.

`CarbRetentionTests.swift` covers the audit reproduction, the derived bounds,
the inclusive cutoff, meals just inside and just outside the bound with and
without counteraction effects, the overrun and delay tails, overlapping meals,
chained tuning and diagnostics through `HistoricalReplay`, and the validation.
