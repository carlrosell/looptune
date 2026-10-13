# 0011. Show the pump value and an interpolated alternative for blocks without evidence

- **Status:** Proposed
- **Date:** 2026-10-13
- **Deciders:** Project owner
- **Related:** [#37](https://github.com/carlrosell/looptune/issues/37), [#12](https://github.com/carlrosell/looptune/issues/12) (CORE-01), [#13](https://github.com/carlrosell/looptune/issues/13) (CORE-02), [#15](https://github.com/carlrosell/looptune/issues/15) (CORE-04), [ADR 0004](0004-historical-replay-context.md), [ADR 0007](0007-measure-tuning-evidence-by-cgm-duration.md)

## Context

A basal hour, ISF block or carb-ratio block can lack usable evidence under the
final settings. The tuners then carried the block's current value forward,
capped to the pump-relative limits (CORE-01), and flagged it untuned. When the
current pump profile was activated after the analysis window, that value came
from the old profile. #26's pipeline case returned ISF 57.143 against pump 40,
labelled "no data" with a "large" change tier.

For basal, `BasalTuner` also smoothed hours it had not adjusted, as oref0 does:
`0.8 × own + 0.1 × previous adjusted + 0.1 × next adjusted`, where "own" was the
carried value. ISF and carb ratio had no equivalent, so the three parameters
treated missing evidence differently.

oref0, AndroidAPS and AutotuneWeb seed from the current profile, so a block
without data effectively keeps the pump value. None of them recommends a
historical value that differs from it. oref0's basal smoothing is the closest
precedent for using neighbouring blocks.

Values are never copied into Loop automatically. The user types each one into
the pump app, so the user can choose between candidate values.

## Decision

**Insufficient evidence.** A block has insufficient evidence when its tuner
reached a no-evidence or rejected path in every chained day of the final
settings period (the CORE-04 epoch, ADR 0004):

- a basal hour that no basal-categorized CGM time informed (ADR 0007's
  duration-based evidence, after the h−3…h−1 attribution);
- an ISF block with less than 50 minutes of usable ratios, or a rejected
  computation;
- a carb-ratio block with no eligible meal grams, or a rejected computation.

`TuningOutput` keeps reporting these blocks as untuned. A basal hour whose
evidence called for no change is tuned: its evidence supports the current rate.
Previously such an hour was untuned because its rate had not moved.

**Recommendation.** LoopTune makes no recommendation for such a block. Its
recommended value is the pump value: unchanged, `minimal` tier, the pump's own
guardrail status. The value the tuner carried forward is used only as the
chained replay hypothesis and never reaches the recommendation. A basal hour's
entered rate is the exact pump rate, not rounded to the increment.

**Interpolated alternative.** Beside the pump value, the block offers a value
interpolated from evidence-backed blocks in the same schedule:

- Blocks form a cycle over the day, so the search wraps at midnight.
- Take the nearest evidence-backed block before and after, and weight each by
  the time between block midpoints:
  `(before × dAfter + after × dBefore) / (dBefore + dAfter)`.
- When only one block in the schedule has evidence, both directions reach it
  and its value is used.
- When no other block has evidence, including a single-block schedule such as
  a flat carb ratio, there is no alternative and only the pump value is shown.
- Neighbour values are their final recommended values: guardrail-clamped for
  ISF and carb ratio, inside the hour's limits and unrounded for basal.
- The result is capped to the block's own pump-relative limits (CORE-01),
  rounded to 3 decimals, and then clamped to Loop's guardrails. A basal
  alternative is rounded to the pump increment within the hour's limits like
  a recommendation (CORE-02).

The alternative carries its own change tier and guardrail status, relative to
the pump value. They describe the alternative, not a tuned change.

**Basal smoothing.** `BasalTuner` no longer smooths hours without evidence; it
keeps their current rate within the caps, as the ISF and carb-ratio tuners
do. The interpolation above replaces the smoothing for every parameter. An
internal `oref0Smoothing` mode keeps oref0's exact behavior so the parity
fixtures still pin oref0's complete output.

**Contract.** `ParameterScheduleRecommendation` and `BasalHourRecommendation`
gain an optional `insufficientEvidence` holding the alternative and its source
start offsets, plus a derived `evidenceStatus`: `tuned`, `insufficientData`,
or `carriedForward`. The last describes untuned blocks in runs saved before
this decision, which have no `insufficientEvidence` and keep the value their
version stored. Every output marks insufficient blocks, names the sources, and
shows both values:

- The app's results show a warning, both values in each schedule and the basal
  table, and a note per block. A saved run's history row warns when it has such
  blocks.
- The text report adds a warning line, a "Choose: pump … or interpolated …"
  line and note per ISF or carb-ratio block, and both values per basal hour.
  A parameter whose blocks all lack evidence shows no average.
- The JSON export keeps every existing key. `recommended` and
  `recommendedRounded` hold the pump value for these blocks. New fields are
  `evidenceStatus`, `interpolated` (value, rounding, tier, status and sources)
  and `note`.
- The Loop schedule keeps the pump rate as each entry's `rate`, marks the entry
  and lists the interpolated rate and sources. Such entries never merge with
  tuned hours.

## Alternatives considered

- **Recommend the interpolated value.** The issue's first brief. It presents a
  value without evidence of its own as LoopTune's recommendation. The user
  chose to see both values and decide.
- **Keep the capped carried value.** This is the behavior #26 exposed: a
  historical value no other tool would recommend, shown with a large change
  tier.
- **Recommend the pump value with no alternative.** Safe, but discards the
  information neighbouring blocks provide, which oref0 also uses.
- **Keep oref0's basal smoothing in production.** It mixes the carried value
  into the result, does not wrap at midnight, and has no counterpart for ISF
  and carb ratio.
- **Distance between block start times.** For blocks of unequal length the
  midpoint is the block's centre of time; start times would favour the later
  neighbour of a long block. For hourly basal both give the same weights.
- **Interpolate during chained tuning.** Feeding interpolated values into the
  next day's replay would make an unsupported value part of the hypothesis
  that later evidence is tested against.
- **Drop the oref0 smoothing code and only assert the tuned hours in the
  parity tests.** It removes code used only by tests but leaves 21 of 24 hours
  in two fixtures unpinned against oref0.

## Consequences

A block without evidence never presents a change on its own. In particular
the #26 case now shows ISF 40, the pump value, with no alternative because no
ISF block has evidence. Daily averages, the daily basal totals, the Loop
schedule's rates and the diagnostics "after" replay use the pump value for
these blocks.

Basal results change in two ways. A single run no longer moves hours without
evidence toward their neighbours. In chained runs an hour without evidence on
one day keeps its rate into the next day instead of drifting 20% toward its
neighbours, so an hour later tuned starts from its own value. The `untuned`
flag and days-missing count for an hour now follow evidence rather than whether
the rate moved, so flat glucose counts as evidence for the current rates.

The tuners' carried values and caps are unchanged and still feed chained
replay. `ScheduleTuningOutput.tunedValue` for an untuned block is that carried
value and must not be presented.

Saved runs without the new key decode with `carriedForward` status and render
as before. Older versions ignore the new key, so they still read new runs and
show these blocks as untuned at the pump value.

`NoEvidenceInterpolationTests` covers the rule (between neighbours, one-sided,
none, wrap at midnight, a scalar), caps, guardrails and rounding of the
alternative, the pipeline result, the report, JSON and Loop schedule, and
legacy decoding. `NoEvidenceCapTests` pins the #26 case. The oref0 parity
tests run in both basal modes.
