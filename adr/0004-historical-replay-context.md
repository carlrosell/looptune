# 0004. Replay inputs with the settings recorded at their start

- **Status:** Accepted
- **Date:** 2026-10-12
- **Deciders:** Project owner
- **Related:** [#17](https://github.com/carlrosell/looptune/issues/17) (CORE-06), [Repository audit](../docs/code-reviews/2026-10-12-repository-audit-review.md#core-06-profile-changes-reinterpret-doses-from-before-activation), [#18](https://github.com/carlrosell/looptune/issues/18) (CORE-07), [#11](https://github.com/carlrosell/looptune/issues/11) (DATA-04), [#15](https://github.com/carlrosell/looptune/issues/15) (CORE-04)

## Context

Replay passed one `TherapyProfile` to `ReplayEngine`, which expanded it over
the whole input window: the analysis interval plus up to 18 hours of retained
doses and 10 hours of carbs and glucose. The pinned LoopAlgorithm model looks up
insulin sensitivity at each dose's start and the carb ratio and sensitivity at
each meal's start. It nets temp basals against the basal scheduled at each
instant. Splitting the analysis at a profile activation therefore did not stop
the new profile from reinterpreting earlier inputs. A 1 U bolus given under
ISF 40 one hour before ISF 80 took effect produced a first post-change insulin
effect of -2.152340 mg/dL instead of -1.076170.

`ChainedTuner` and `DiagnosticsBuilder` each built their own replay loop from
day windows, profile segments, input trimming, replay, and override filtering.
The diagnostics "after" replay ignored profile history entirely. Nothing kept
the two callers' transition behavior aligned.

Chained tuning also replays a hypothesis rather than recorded history: each
day's tuned profile seeds the next day's replay. A rule was needed for how that
hypothesis composes with the settings actually recorded earlier.

## Decision

Replay uses a `TherapyTimeline`, a sequence of settings periods. For each
analysis segment, the timeline is:

- the recorded profile history before the activation of the segment's settings
  period, and
- a candidate profile from that activation onward.

The activation is the start of the uninterrupted run of recorded profiles whose
basal, ISF, and carb-ratio schedules, time zone, and insulin type match those
active at the segment start. A target-only or limit-only upload does not start
a new period. Each period's schedules are expanded with `DailySchedule.expand`
in that profile's own time zone. Doses without an explicit insulin type take
the type of the profile in force at their start.

Every period boundary is a cut in the basal, ISF, and carb-ratio timelines,
even where a schedule has the same value on both sides. The pinned
LoopAlgorithm splits a temp basal only at basal timeline boundaries and models
each part with the ISF in force at that part's start. Without the cut, a temp
basal crossing an ISF-only change would be modeled entirely with the earlier
ISF.

The candidate stands in for the settings period being analyzed. Inputs that
began under an earlier period keep the settings recorded for their start.
Inputs that begin after the activation use the candidate. A temp basal that
crosses the activation is split at the activation, whether or not the basal
rate changes there. The part delivered before it keeps the recorded basal and
ISF, and the part after it uses the candidate's. Both parts keep the insulin
type resolved at the dose's start.

- Recorded-history replay (the diagnostics "before" replay) uses the recorded
  profile as the candidate, so it replays the recorded history throughout.
- Chained tuning uses the evolving tuned profile. Within one settings period it
  replaces the recorded settings for every input since the activation,
  including inputs retained from before the analysis start. A settings change
  resets the evolving profile and the CORE-04 `Epoch` together.
- The diagnostics "after" replay uses the recommended profile for every
  settings period, with the same composition rule.

Without profile history, or for a segment earlier than every recorded
activation, the candidate applies throughout. This matches the existing
`ProfileHistory.activeProfile(at:)` fallback to the earliest known profile.

`HistoricalReplay` in `LoopTuneKit/Replay` owns this context for both callers:
04:00 day windows, the split at therapy activations, input retention through
`ReplayEngine.trimmedInputs`, the timeline, and override filtering. A caller
supplies only the candidate profile for each segment. `ReplayEngine` keeps its
single-profile entry point, which builds a one-period timeline and produces
the same schedules as before.

`TuningPipeline` uses chained tuning when a therapy change falls inside the
analysis window or within `ReplayEngine.inputLookback` before it. Its
single-replay path applies one profile and remains only for windows with no
recorded change among the retained inputs.

## Alternatives considered

- **Split the analysis at activations only.** This was the previous behavior.
  It separates evidence but leaves earlier inputs modeled with the new settings.
- **Exclude samples whose inputs began before an activation.** This would drop
  the hours of evidence after each change in which earlier insulin or carbs
  are still active, even though the model can represent those inputs exactly
  with the recorded schedules.
- **Recorded history for every input, candidate only for scoring.** The
  candidate would then never affect basal netting or sensitivity, so chained
  tuning could not test its hypothesis. That would diverge from oref0's
  chaining model, which replays with the previous day's tuned profile.
- **Apply the candidate across the whole lookback, as oref0 does.** oref0 has
  no profile history, so it has no transition to model. LoopTune does, and
  this is the reinterpretation the audit found.
- **Fix each caller separately.** Tuning and diagnostics would again carry
  their own segmentation and trimming, which is how they had already diverged.

## Consequences

Every input is modeled with the settings in force when it began, in tuning and
in both diagnostics replays. The diagnostics "after" replay now differs from
the earlier recommended-everywhere replay near activations, where earlier
inputs keep their recorded settings.

Replay accuracy depends on profile history covering the earliest retained input.
`ReplayEngine.inputLookback` names that span for profile fetching (DATA-04).
History that does not reach it falls back to the earliest known profile; this
decision does not detect that gap. DATA-04
([#11](https://github.com/carlrosell/looptune/issues/11), PR
[#36](https://github.com/carlrosell/looptune/pull/36)) handles it at the
pipeline boundary: fetching extends profile history to
`analysisStart - inputLookback` or throws when the fetched history is
truncated. A site whose complete history starts after that boundary still uses
its earliest profile there.

Input retention stays in `ReplayEngine.trimmedInputs` and its lookback
constants. The timeline is built over whatever the retained inputs span, so
CORE-07 can lengthen carb and glucose retention without changing this rule.
`inputLookback` grows with it.

A one-day run with a change in the 18 hours before the window now takes the
chained path. Its recommendation reports `daysTuned` and per-hour days missing
like other chained runs.

Regression tests in `HistoricalReplayTests.swift` replay the audit's bolus case
and cover pre-change temp basals, pre-change meals, and post-change inputs.
A temp basal crossing the activation must equal its explicitly split parts
for basal-only, ISF-only, carb-ratio-only, and combined changes. Further tests
cover a return to earlier settings, a recorded period in another time zone,
and the insulin type recorded for each period. The chained tuner and pipeline
recommendations must equal those for an equivalent input expressed under the
new settings. Both diagnostics replays must keep the recorded settings for
pre-change inputs.
