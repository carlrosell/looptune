# 0007. Measure tuning evidence by CGM duration

- **Status:** Proposed
- **Date:** 2026-10-12
- **Deciders:** Project owner
- **Related:** [#16](https://github.com/carlrosell/looptune/issues/16) (CORE-05), [Repository audit](../docs/code-reviews/2026-10-12-repository-audit-review.md#core-05-cgm-cadence-changes-tuning-weight-and-the-minimum-evidence-duration), [#17](https://github.com/carlrosell/looptune/issues/17) (CORE-06)

## Context

`ReplayEngine` produces one `DeviationSample` per accepted CGM interval and
scales its glucose changes to five minutes. The tuners then treated every
sample as one five-minute datum. They summed basal and meal residuals with equal
weight and counted readings against the evidence minimums. A one-minute sensor
therefore counted five times over, and fifteen-minute data a third as much.

On `main` at 0ea1742, the same three-hour rise of 3 mg/dL per five minutes
produced hour-3 basal recommendations of 1.2, 1.097 and 1.037 U/h at 60, 300
and 900-second spacing. Total evidence was 180, 36 and 12 samples. A 12-minute
window of one-minute CGM passed the pipeline's 12-sample minimum, which is
documented as one hour. The ISF minimum of ten data points and the chained
per-day minimum had the same defect.

These counts are public. `TuningOutput`, `TuningRecommendation`, the CLI JSON,
saved runs and `HourDeviation` all expose them, and
`TuningPipeline.PipelineError.insufficientUsableData(minimum:actual:)` reports
the pipeline minimum.

## Decision

Each `DeviationSample` carries `duration`, the seconds between the CGM readings
that bound it. Its glucose changes stay as five-minute rates, so per-datum
categorization thresholds and ISF ratios are unchanged. The default `duration`
is five minutes.

Every aggregate weights a sample by `duration / 5 min`:

- `BasalTuner` hourly deviation sums.
- Meal residual sums in `CarbRatioTuner` and its schedule tuning.
- The ISF median, which becomes a weighted form of oref0's percentile. With
  equal weights it returns exactly the unweighted result.
- Diagnostics hourly and overall mean deviations.

Evidence is measured in five-minute intervals of CGM time: the summed
duration divided by five minutes, rounded to the nearest interval. This is the
unit of `totalSamples`, `categoryCounts`, `basalSampleCountByHour`,
`excludedOverrideSamples`, ISF `evidenceCount`, `HourDeviation.sampleCount`,
and both `insufficientUsableData` values. The pipeline and chained per-day
minimums are one hour, `TuningPipeline.minimumEvidenceDuration`, expressed as
`minimumUsableSamples = 12` intervals. ISF needs ten intervals, or 50 minutes,
of usable ratios.

Field names and types stay the same. Regular five-minute data produces the same
values as before, so saved runs and JSON consumers need no migration.

## Alternatives considered

- **Resample replay onto a fixed five-minute grid.** This makes every sample
  exactly one datum but invents interior glucose values for long intervals and
  discards resolution from fast sensors. Unaligned five-minute data would also
  change, which would break existing behavior and require larger
  `ReplayEngine` changes alongside the CORE-06 replay work.
- **Report durations in new fields and leave counts as readings.** This keeps
  the reading count accurate but leaves two evidence measures that disagree
  for non-five-minute sensors. It also needs new persisted fields and a
  migration for existing saved runs.
- **Change the error to carry minutes.** Five-minute intervals already
  appear in every other evidence field. The app converts to minutes when it
  displays the message.

## Consequences

Equivalent trajectories carry equal total weight and evidence at any cadence. A
residual difference remains in hourly attribution. Each interval belongs to
the clock hour of its end time, as in oref0, so evidence near an hour boundary
can shift by less than one CGM interval between adjacent hours. In the
regression trajectory this changes a basal rate by at most 0.01 U/h and leaves
every rate in the same 0.05 U/h pump increment.

Five-minute data with missed readings now counts each gap in proportion to its
duration, up to the 20-minute maximum gap. Previously a gap counted as one
datum. Jittered five-minute timestamps round to the expected number of
intervals.

A one-minute run reports about a fifth as many "samples" as readings. The
evidence fields document the unit, and the app reports the minimum in
minutes. `CadenceIndependenceTests` verifies the contract, and the oref0 parity
fixtures pin five-minute behavior.
