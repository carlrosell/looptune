# LoopTune — Implementation Plan & Status

> Living document. Every phase has a **status** and a checklist. Update the
> status table and the phase checklists as work lands. Keep the "Status log"
> at the bottom append-only so we can always see how we got here.

---

## 1. Vision

A native macOS app (SwiftUI + Swift Package Manager) that fetches a Loop user's
Nightscout history (CGM, insulin, carbs, overrides, profile) and recommends
tuned therapy settings — **basal schedule, insulin sensitivity factor (ISF),
and carb ratio (CR)** — by replaying that history through **Loop's own
algorithm models**, not oref0's.

It is the Loop-native analogue of [AutotuneWeb](https://github.com/MarkMpn/AutotuneWeb)
and its successor [nighttune](https://github.com/houthacker/nighttune), which
wrap oref0 autotune for OpenAPS/AndroidAPS users.

### Why not just run oref0 autotune (like nighttune does)?

The reference research (see `references/notes/`) makes the case concrete: oref0
autotune's output is **not valid for Loop users** because the two systems use
different physiological models. Specifically:

- **Insulin model mismatch.** oref0 clamps DIA to 5 h (300 min); Loop uses a
  6 h (360 min) exponential curve and defines ISF as the drop from 1 U over the
  *full* 6 h. Consequence: a correct Loop ISF is typically **2–3× larger** than
  the equivalent oref0/pre-Loop correction factor. Transplanting oref0's ISF/CR
  into Loop under-doses corrections — a safety problem. (Source: Loop and Learn,
  loopdocs prediction; `references/notes/07-prior-art.md` §2d.)
- **Temp-basal / autobolus upload semantics.** Loop's Automatic Bolus delivers
  up to 40% of needed insulin as discrete boluses, and Omnipod pulse timing
  distorts the `amount` field oref0 doesn't fully consume — so oref0 mis-splits
  basal vs ISF for Loop data. (oref0 issue #1362; `07-prior-art.md` §2a–2c.)
- **No UAM in Loop.** Loop requires carb entries and uses dynamic absorption;
  oref0's UAM handling doesn't correspond to anything Loop does.

**LoopTune's key idea:** compute the per-5-minute glucose *deviations* (insulin
counteraction effect minus modeled carb effect) using the **real LoopKit
`LoopAlgorithm` Swift package** — Loop's exact exponential insulin model,
dynamic piecewise-linear carb absorption, and ICE pipeline — and then apply an
**autotune-style tuning layer** (adapted from oref0's well-understood
categorization + adjustment math) on top of those Loop-native deviations. The
result is a recommendation expressed in Loop's own model, so it is semantically
valid to enter into Loop's therapy settings.

> This is a novel synthesis: oref0's *tuning structure* over LoopAlgorithm's
> *forward model*. No prior tool does exactly this (the defunct LoopKit `Learn`
> app replayed effects but never shipped a settings tuner — `07-prior-art.md` §3).

### Non-goals

- Not a medical device; **never auto-applies** settings. Advisory only, with
  loud disclaimers and mandatory human review (matches Loop's design philosophy
  of user-controlled therapy settings).
- No pump/loop control, no writing back to Nightscout in v1 (a later, clearly
  gated "upload as new profile" feature is possible — nighttune has it — but
  off by default and out of the initial scope).
- Does not tune DIA/insulin-peak or targets (Loop doesn't let users edit the
  insulin model in-app, and targets are a personal/clinical choice).

---

## 2. High-level architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ LoopTuneApp (SwiftUI macOS)      LoopTuneCLI (headless, testable) │
└───────────────┬─────────────────────────────┬───────────────────┘
                │                             │
                ▼                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                          LoopTuneKit                             │
│                                                                   │
│  Nightscout/    HTTP client, auth (token/api-secret/JWT), DTOs,   │
│                 per-day windowed fetch, redirect normalization    │
│      │                                                            │
│      ▼                                                            │
│  Ingest/        NS DTO → domain model; profile schedule expansion │
│                 (timezone/DST) into AbsoluteScheduleValue; temp-  │
│                 basal→dose volume; suspend materialization; carb  │
│                 dedupe/overlap-trim; override exclusion            │
│      │                                                            │
│      ▼                                                            │
│  Replay/        For each 5-min datum: build LoopAlgorithm windows │
│                 and compute deviations = ICE − carbEffect using   │
│                 the real LoopAlgorithm package (Loop's models)    │
│      │                                                            │
│      ▼                                                            │
│  Tune/          Categorize each datum (basal/ISF/CSF/UAM), then   │
│                 tune basal schedule + ISF + CR with day-chaining  │
│                 and safety caps (autotune-adapted logic)          │
│      │                                                            │
│      ▼                                                            │
│  Recommend/     Recommendation model: per-parameter pump vs tuned │
│                 value, day-count/confidence, change tier, Loop    │
│                 guardrail clamping                                 │
│                                                                   │
│  Support/       LoopUnit bridging, timezone, errors, logging      │
└─────────────────────────────────────────────────────────────────┘
                │
                ▼
        depends on  →  LoopKit/LoopAlgorithm  (pinned by revision)
                       apple/swift-argument-parser (CLI)
```

**Dependencies:** `LoopAlgorithm` is pinned by commit `2f5c630…` because the
repository publishes no version tags. Swift Argument Parser is pinned to 1.8.2,
and both resolutions are committed in `Package.resolved`. Platform floor is
**macOS 14** (LoopAlgorithm requires 13; we take 14 for modern
SwiftUI/Observation).

---

## 3. The LoopTune algorithm (the heart)

Adapts oref0 autotune (`references/notes/03-oref0-autotune.md`) but replaces its
internal IOB/BGI/deviation computation with LoopAlgorithm output
(`references/notes/04-loopalgorithm.md`). Reference oref0 numbers are the
starting point; each is a tunable constant we can validate against golden data.

### 3.1 Deviation computation (Loop-native — this is the big departure)

For a replay window, use LoopAlgorithm's public pipeline (all verified public in
`04-loopalgorithm.md` §5, Option B):

```
annotated  = doses.annotated(with: basalSchedule)               // [BasalRelativeDose], nets temps vs scheduled
insulinFx  = annotated.glucoseEffects(insulinSensitivityHistory: isf, from:…, to:…)
ice        = glucose.counteractionEffects(to: insulinFx)        // [GlucoseEffectVelocity], mg/dL/s
statuses   = carbEntries.map(to: ice, carbRatio: cr, insulinSensitivity: isf)   // dynamic absorption
carbFx     = statuses.dynamicGlucoseEffects(from:…, to:…, carbRatios: cr, insulinSensitivities: isf)
deviations = ice.subtracting(carbFx)                            // [GlucoseEffect] per ~5-min CGM interval, mg/dL
```

`deviations[i]` = observed BG change minus (insulin-modeled + carb-modeled)
change over that interval, in mg/dL — **exactly the autotune "deviation" but
computed with Loop's insulin curve and Loop's dynamic carb absorption**.
`ice` velocities are mg/dL/**s** (× 300 for per-5-min mg/dL). We also derive per
datum, from LoopAlgorithm, the equivalents of the oref0 quantities:

| oref0 quantity | LoopTune source |
|---|---|
| `BGI` (insulin-only ΔBG/5m) | difference of consecutive `insulinFx` cumulative values |
| `deviation` | `deviations[i]` (per-interval, already carb-adjusted) |
| `avgDelta` | mean of last 4 five-min glucose deltas (same as oref0) |
| `iob.activity`, `iob.iob` | `insulinOnBoardTimeline(…)` + activity via `insulinFx` slope |
| `basalBGI` | `scheduledBasal(t) × ISF(t) / 60 × 5` (same formula) |
| COB / CSF | LoopAlgorithm `dynamicCarbsOnBoard` / CarbStatus (Loop's model, replaces oref0's `min_5m_carbimpact` decay) |

> **Design note.** oref0 decays COB with a crude `min_5m_carbimpact` floor.
> LoopAlgorithm already produces observed carb absorption from ICE. LoopTune uses
> LoopAlgorithm's COB directly and does **not** reintroduce `min_5m_carbimpact`;
> the "absorbing/meal" categorization keys off LoopAlgorithm COB > 0 and
> CarbStatus activity instead. (Open question OQ-2 below.)

### 3.2 Categorization (adapted from `categorize.js`)

Per 5-min datum, in priority order (oref0 §1.5, `03-oref0-autotune.md`):

1. **CSF (meal)**: LoopAlgorithm COB > 0, or still absorbing (IOB > basal/2 and
   deviation > 0), or recent carb entry active. Tag `mealAbsorption` start/end.
2. **UAM**: `iob > 2×basal || deviation > 6`. Since **Loop has no UAM**, default
   policy is `categorizeUAMAsBasal = true` (nighttune's default is also true) —
   but we keep the reassignment logic (lowest-50% deviation retention) available
   and documented, because unlogged carbs still happen. (OQ-3.)
3. **basal vs ISF**: `if basalBGI > −4×BGI → basal`; else if
   `avgDelta > 0 && avgDelta > −2×BGI → basal`; else **ISF**.

Clamps preserved: skip datum if BG < 40 or BG[i+4] < 40; zero positive
deviations when BG < 80 (post-hypo rebound guard).

### 3.3 Parameter tuning (adapted from `autotune/index.js`)

- **Basal (per hour, 24 slots):** `basalNeeded(h) = 0.2 × Σdeviations(h) / ISF`.
  Positive → add `basalNeeded/3` to hours h−3, h−2, h−1 (wrap mod 24); negative →
  scale those 3 hours by `1 + basalNeeded/threeHourSum`. Then clamp each hour to
  `[pumpRate(h)×autotuneMin, pumpRate(h)×autotuneMax]`. Unused-hour smoothing:
  `0.8×orig + 0.1×lastAdjusted + 0.1×nextAdjusted`, increment `untuned(h)`
  counter (surfaced as "days missing"). Hours evaluated in **profile timezone**.
- **ISF (single value, like oref0):** per ISF datum `ratio = 1 + deviation/BGI`;
  `fullNewISF = ISF × median(ratios)` (needs ≥10 datapoints, else unchanged);
  optional blend toward pump ISF via `adjustmentFraction` (default 1.0 = none);
  `newISF = 0.8×ISF + 0.2×adjustedISF`; clamp `[pumpISF/autotuneMax, pumpISF/autotuneMin]`.
  > Loop supports an ISF *schedule* (up to 48 entries). v1 tunes a single ISF
  > (parity with autotune, simpler, well-validated). Per-slot ISF is a stretch
  > goal (OQ-4).
- **Carb Ratio (single value):** LoopTune's replay has already subtracted the
  modeled carb effect, so meal deviations are residuals rather than raw carb
  impact. It computes
  `CSF_true = replayISF/currentCR + ΣmealResidual/ΣloggedCarbs`, then
  `fullNewCR = tunedISF/CSF_true`, applies the pump-relative 0.7×–1.2× cap,
  and moves 20% toward that value. **Absolute CR bounds use Loop guardrails
  (4–28 recommended, 2–150 absolute), not oref0's 3–150.**

### 3.4 Day chaining & weighting

Run prep+tune per local day chronologically; each day's tuned profile seeds the
next (oref0 model). No explicit averaging — the 20% step yields implicit
exponential recency weighting (`0.2 × 0.8^(k−1)`). All safety caps are computed
against the **fixed pump profile** so multi-day drift is bounded regardless of
window length. Default window 7 days (max 30), matching AutotuneWeb/nighttune.

### 3.5 Safety caps & guardrails

- Per-run multipliers vs pump profile: `autotuneMax = 1.2`, `autotuneMin = 0.7`
  (basal, CR, CSF); ISF inverted (`/0.7`, `/1.2`).
- **Loop guardrails** clamp the final recommendation (from LoopKit
  `Guardrail+Settings.swift`, `07-prior-art.md` §5): Basal 0.05–30 U/hr; ISF
  abs 10–500, rec 16–399 mg/dL/U; CR abs 2–150, rec 4–28 g/U; suspend threshold
  67–110. Present a value outside *recommended* but inside *absolute* with a
  yellow warning; at the absolute limit, red.
- **Change tiers** (from AutotuneWeb): yellow when |Δ| ≥ 10%, red when
  Δ ≥ +20% or ≤ −30%.
- **Confidence:** per basal hour and per parameter, show days-of-real-data vs
  interpolated (AutotuneWeb's green/red strip). Downweight/flag meal-dominated
  basal hours (they get flattened — `03` pitfalls).

---

## 4. Data model (domain types in `Model/`)

- `NightscoutProfile` / `TunableProfile` — basal/ISF/CR/target schedules +
  timezone + units + loop settings (dosingStrategy, suspend threshold, max
  basal/bolus). Schedules stored as time-of-day; expanded to
  `AbsoluteScheduleValue<…>` timelines per day for LoopAlgorithm.
- `GlucoseSample` (mg/dL, provenance constant for replay), `DoseRecord`
  (bolus/tempBasal/suspend → LoopAlgorithm `FixtureInsulinDose` with absolute
  volume), `CarbRecord` (grams + absorptionTime), `OverridePeriod`.
- `DeviationSample` — timestamp, BG, avgDelta, BGI, deviation, IOB, COB,
  category, meal/uam flags.
- `TuningResult` — tuned basal schedule, ISF, CR, plus per-parameter
  `Recommendation { pumpValue, tunedValue, changePercent, tier, daysMissing,
  guardrailStatus }`.

Persistence uses the LoopAlgorithm **Fixture** Codable types (the non-Fixture
`AlgorithmOutput` is Encodable-only — `04` pitfalls), so replay inputs/outputs
serialize cleanly for golden tests.

---

## 5. Reference-parity & correctness strategy

The reference repos are production-grade; we mine them for exact numbers and use
them as oracles:

1. **LoopAlgorithm golden fixtures.** Reuse the package's own JSON fixture format
   (`AlgorithmInputFixture` / `LoopAlgorithmRunner`). Our replay must reproduce
   LoopAlgorithm's `insulinCounteraction` / effects bit-for-bit for shared
   inputs (they're the same package — this validates our *wiring*, not the math).
2. **oref0 tuning parity harness.** Port a handful of oref0
   `autotune.<date>.json` → `newprofile.<date>.json` cases as fixtures and check
   our tuning *structure* matches oref0 when fed oref0-style deviations (isolates
   tuning-logic bugs from model differences).
3. **Nightscout DTO fixtures.** Capture real-shaped (anonymized) NS documents
   from the formats documented in `06` and round-trip them through Ingest.
4. **Property tests.** Guardrail clamping, timezone/DST bucketing, temp-basal
   overlap trimming, unit conversion (mmol×18), schedule expansion.

---

## 6. Phased plan & status

Status legend: ⬜ not started · 🟡 in progress · ✅ done · ⏸️ blocked

| # | Phase | Status |
|---|-------|--------|
| 0 | Repo, package scaffold, CI, dependency wiring | ✅ |
| 1 | Domain model + LoopAlgorithm bridging types | ✅ |
| 2 | Nightscout client (auth, endpoints, windowed fetch) | ✅ |
| 3 | Ingest: NS → domain (profile expansion, doses, carbs, TZ) | ✅ |
| 4 | Replay: deviation computation via LoopAlgorithm | ✅ |
| 5 | Tune: categorization + basal/ISF/CR tuning + chaining | ✅ |
| 6 | Recommendations: guardrails, tiers, confidence | ✅ |
| 7 | CLI end-to-end (`fetch` / `tune`) | ✅ |
| 8 | SwiftUI app (wizard + results + charts) | ✅ |
| 9 | Hardening: golden fixtures, edge cases, security, docs | ✅ |

### Phase 0 — Scaffold ✅
- [x] Git repo, MIT license, README, .gitignore
- [x] Private GitHub repo `carlrosell/looptune`, pushed
- [x] SwiftPM package: `LoopTuneKit` lib + `looptune` CLI + `LoopTuneApp`
- [x] Depend on pinned `LoopAlgorithm`; `swift build` + `swift test` green
- [x] GitHub Actions CI (build + test on macOS)
- [x] Clone reference repos + capture research notes under `references/notes/`

### Phase 1 — Domain model + bridging ✅
- [x] `GlucoseSample`, `DoseRecord`, `CarbRecord`, `OverridePeriod`, `TherapyProfile`
- [x] Time-of-day schedule types (basal/ISF/CR/target) with `value` coercion (`DailySchedule`)
- [x] Expansion to `AbsoluteScheduleValue` timelines honoring timezone/DST
- [x] `GlucoseUnit` mmol↔mg/dL + `NightscoutTimeZone` (ETC/GMT sign inversion)
- [x] Adapters from domain doses/carbs/glucose to LoopAlgorithm fixture types
- [x] `InsulinType` (Sendable mirror of `FixtureInsulinType`)
- [x] Unit tests: schedule expansion, DST spring-forward, unit conversion, TZ parsing (25 tests green)

### Phase 2 — Nightscout client ✅
- [x] URL normalization (strip pasted paths/query/fragment)
- [x] Auth: `?token=`, `api-secret` (SHA-1 hex via CryptoKit); JWT deferred (token covers reads)
- [x] Auth probe `/api/v1/experiments/test` (`checkAuthorized`)
- [x] Endpoints: entries/sgv, treatments, profile history, status
- [x] Windowed fetch (epoch-ms entries, ISO treatments) + explicit `count`
- [x] Lenient DTOs (string numbers, bools, fractional-second + epoch dates)
- [x] Injectable `NightscoutTransport` + stub-based tests (39 tests green)
- [ ] devicestatus endpoint + JWT (deferred — not needed for core tuning)
- [x] Per-day fetch orchestration with dose/carb/glucose lookback padding (implemented in pipeline/cache)

### Phase 3 — Ingest ✅ (core)
- [x] Profile doc → `TherapyProfile` (store[defaultProfile], TZ incl. ETC/GMT sign inversion, mmol→mg/dL for ISF/targets/suspend threshold)
- [x] Temp Basal → effective rate (`amount/duration` preferred; else `rate`/`absolute`); suspend (rate 0 / reason) → suspend dose
- [x] Overlap trimming (sort, clip to next start, drop zero-length); skip percent temps lacking absolute rate
- [x] Bolus → dose (delivered `insulin`; automatic flag; square via `duration`)
- [x] Carb Correction / Meal Bolus → `CarbRecord` (absorptionTime default 3h; ±2s dedupe)
- [x] Override periods → scale factor + correction range; indefinite closed at next override
- [x] Glucose entries → samples (filter <39, sort, dedupe)
- [x] Tests: mmol conversion, overlap trim, suspend, dedupe, indefinite override (53 tests green)
- [x] Profile-history alignment at exact `startDate` changes
- [x] Fill scheduled-basal gaps for LoopAlgorithm annotation

### Phase 4 — Replay ✅ (core)
- [x] Coverage-safe schedule timelines spanning all inputs + insulin tail (avoids `preconditionFailure`)
- [x] Pipeline: `annotated(fillBasalGaps)` → `glucoseEffects` → `counteractionEffects` → carb `map(to:)` → `dynamicGlucoseEffects`
- [x] Per-interval deviation = observed ΔBG − modeled insulin ΔBG − modeled carb ΔBG
- [x] `DeviationSample` with deviation, insulin effect (BGI), avgDelta, IOB, COB
- [x] Constant glucose provenance for ICE continuity; sorted fixture arrays
- [x] `CumulativeEffectLookup` (interpolated, off-grid CGM timestamps)
- [x] Guards: skip BG<40, long CGM gaps (>20min), post-hypo rebound zeroing
- [x] Tests: no-insulin (deviation = ΔBG), bolus (10-min delay then negative effect), carb absorption, gap skipping (63 tests green)
- [ ] `PrecomputedInsulinInput` fast path — optional future optimization; the current tuner does not sweep candidates

### Phase 5 — Tune ✅
- [x] Categorizer (CSF/UAM/basal/ISF) with post-hypo + gap clamps
- [x] UAM reassignment policy (default UAM→basal for Loop)
- [x] Basal per-hour tuner (h−3…h−1 distribution) + unused-hour smoothing + pump-relative caps
- [x] ISF median-ratio tuner (≥10 pts, negative-ratio guard, adjustmentFraction, inverted caps)
- [x] CR tuner in **carb-sensitivity space** (Loop-native residual, not oref0 raw impact — see design note below)
- [x] `LoopTuner` orchestrator + `TuningOutput`; oref0-faithful percentile
- [x] Tests: math primitives, categorizer, all three tuners with sign checks (78 tests green)
- [x] Day-chaining harness (04:00 windows, exact profile-change splits, evolving profile, fixed pump cap baseline)
- [x] oref0 parity tests on ported prep→core fixtures
- [ ] Full CRData meal-period tuner (alternative to CSF method) — future

> **Design note (CR tuning).** oref0's CR method treats the meal-interval
> deviation as the carb impact itself. In LoopTune the replay already subtracts
> the modeled carb effect, so a CSF deviation is the carb-model *residual*. The
> tuner therefore works in carb-sensitivity space:
> `CSF_true = replayISF/currentCR + Σresidual/Σcarbs`, `CR = tunedISF/CSF_true`.
> A naive port (residual used as impact) moved CR the wrong way — caught by a
> sign test.

### Phase 6 — Recommendations ✅
- [x] Loop guardrail clamping + status (ok / outside-recommended / at-limit)
- [x] Change tiers (minimal / notable ≥10% / large ≥+20% or ≤−30%)
- [x] Per-parameter + per-hour untuned/"no data" flags; category counts
- [x] `TuningRecommendation` model + autotune-style text report with disclaimer
- [x] JSON serialization (`RecommendationJSON`)
- [x] Tests: guardrail clamp, tiers, end-to-end pipeline render (84 tests green)
- [x] Per-hour day-count confidence and evidence counts

### Phase 7 — CLI ✅
- [x] `looptune tune <url>` (full pipeline → table or `--json`)
- [x] `looptune fetch <url>` (diagnostic: counts, timezone, units, auth probe)
- [x] Config: URL, `--token`/`--api-secret`, `--days`, `--insulin` flags
- [x] `TuningPipeline` orchestrator (online fetch + offline inputs paths)
- [x] Verified end-to-end against a mock Nightscout server (`references/mock_nightscout.py`)
- [ ] `report` from saved JSON + golden CLI output tests (nice-to-have)

### Phase 8 — SwiftUI app ✅ (core)
- [x] `@Observable` `TuningViewModel` running the pipeline off the main actor
- [x] Split-view UI: connection/options form + results pane (idle/running/error/done)
- [x] Results: ISF/CR cards + basal table with pump vs tuned + tier coloring + "no data" flags
- [x] Prominent medical disclaimer banner
- [x] Builds and launches as a native macOS app (verified process starts)
- [x] Charts (basal curve and per-hour deviation coverage)
- [x] Keychain token storage per host/port; persisted URL sanitization
- [ ] Profile picker and snapshot/UI automation tests (future)

### Phase 9 — Hardening ✅ (core)
- [x] Two `coderabbit` CLI passes; all findings addressed (or documented as intentional)
- [x] Element-level array decoding with visible partial-corruption failure; DST spring-forward test; ETC/GMT cases
- [x] README usage docs; medical disclaimer everywhere output is produced
- [x] COB precompute perf fix (O(intervals) not O(intervals×carbs))
- [x] **Multi-day chained tuning** (`ChainedTuner`): 4am-local day windows, evolving
      profile, pump-anchored caps, per-hour days-missing + coverage accumulation,
      daily ISF/CR trajectories; pipeline chains any window > 1 day
- [x] **oref0 golden parity fixtures**: generated by running oref0's real
      `tuneAllTheThings` (commit 88cf032) via `node references/gen_oref0_fixtures.js`;
      SensitivityTuner and BasalTuner match oref0 to ±0.001 on all scenarios after
      reproducing its exact rounding (3dp sums/rates, 2dp basalNeeded, 3dp p50) and
      smoothing quirks (forward pass, live-array reads, 0/23 defaults, no wrap)
- [x] **Charts in the app** (Swift Charts): basal pump-vs-tuned step chart + per-hour
      data-coverage bars; series colors validated with the dataviz palette validator
      in light and dark modes (blue/aqua categorical pair)
- [x] **Keychain storage**: token stored per-host in the login Keychain;
      URL/days/insulin remembered in UserDefaults; restored on launch, saved on
      successful runs
- [ ] `PrecomputedInsulinInput` fast path for 30-day sweeps (perf, only if needed)
- [ ] Snapshot/UI tests for the app (future)

---

## 7. Open questions / decisions to revisit

- **OQ-1 (settled).** Use LoopAlgorithm for the forward model + oref0-adapted
  tuning layer. Rationale in §1.
- **OQ-2.** Should categorization COB come purely from LoopAlgorithm's dynamic
  absorption, or do we keep a `min_5m_carbimpact`-style floor for robustness on
  sparse data? Leaning: pure LoopAlgorithm COB; revisit if meal periods look
  unstable on real data.
- **OQ-3.** UAM handling for Loop: default UAM→basal. Expose as an option?
  nighttune defaults `uam_as_basal = true`. Likely keep as an advanced toggle.
- **OQ-4.** Tune a full ISF *schedule* (Loop supports 48 entries) vs a single
  ISF (autotune parity)? v1 = single; schedule is a stretch goal.
- **OQ-5 (settled for v1).** Exclude intervals whose override changes insulin
  needs from basal/ISF/CR attribution and report the excluded sample count.
- **OQ-6.** Write-back to Nightscout as a new profile (nighttune has it). Out of
  v1 scope; if added, gate behind explicit confirmation + `api:profile:*` roles.

---

## 8. Status log (append-only)

- **2026-07-25** — Whole-application adversarial review completed. Every
  first-party file was read and tracked in
  `docs/code-reviews/2026-07-25-whole-application-review.html`. Fixed 15 findings
  spanning override attribution, exact profile-change timing, historical
  insulin models, minimum evidence, basal cap enforcement, irregular CGM
  normalization, strict Nightscout/profile validation, TLS and stale-token
  handling, dependency locking, complete treatment deduplication, private and
  traversal-safe persistence, diagnostic claims, disclaimers, UI failure
  visibility, and stale documentation. The suite now covers app URL handling,
  malformed/partial data, calculation boundaries, persistence permissions,
  backward-compatible saved runs, and recommendation safety.

- **2026-07-12** — Performance: chained tuning was quadratic (each day window
  replayed the entire multi-day dataset) and diagnostics added two more
  full-window replays. `ReplayEngine.trimmedInputs` now trims each replay to
  the physically relevant inputs (doses 18h back, carbs/glucose 10h back), the
  chained tuner and diagnostics both use it, and the diagnostics before/after
  replays run as concurrent child tasks. Benchmark (7 days, 5-min temp basals,
  debug build): tune 34.7s → 2.1s, diagnostics 8.7s → 2.4s (~10× overall).
  122 tests green — trimming preserves results exactly (insulin tail and carb
  absorption windows are fully covered by the lookbacks).

- **2026-07-04** — Run history + diagnostics tab. Completed runs are persisted
  (`RunStore`, one JSON per run under Application Support, newest-50 kept) and
  listed in the sidebar; selecting one reopens it. The detail pane is now two
  tabs: Recommendations and Data & diagnostics. `DiagnosticsBuilder` replays the
  window twice — current settings vs recommended — and reports the mean-absolute
  deviation improvement, per-hour before/after deviation (chart + flagged
  table), and per-day ingested-data summaries (CGM count, mean, TIR, boluses,
  insulin, carbs). `TuningRecommendation`/`RunDiagnostics`/`SavedRun` are
  Codable for persistence. 122 tests green.

- **2026-07-04** — Local day cache. `DayCache` stores raw Nightscout documents
  per site host and UTC day under Application Support, in wire format (DTOs
  gained symmetric `Encodable`). The pipeline fetches per day bucket, serves
  finished days from disk, never caches days younger than 24h (Loop's
  retroactive-edit window), dedupes boundary documents, and prunes days older
  than 30 days on every run. Used by the app and CLI (`--no-cache` opt-out).
  109 tests green; verified against the mock server (finished days cached,
  fresh days fetched live).
- **2026-07-04** — Repo initialized; scaffold (LoopTuneKit/CLI/App) builds and
  tests green against pinned LoopAlgorithm; CI added; pushed to
  `carlrosell/looptune` (private). Ran a 7-agent research workflow over
  nighttune, AutotuneWeb, oref0, LoopAlgorithm, loopdocs, Nightscout/Loop data
  formats, and prior art; distilled notes saved under `references/notes/`.
  Wrote this plan. Core architectural decision (OQ-1) settled: LoopAlgorithm
  forward model + oref0-adapted tuning.
- **2026-07-04** — Phase 1 done. Domain model (`GlucoseSample`, `DoseRecord`,
  `CarbRecord`, `OverridePeriod`, `TherapyProfile`, `InsulinType`) plus the
  reusable `DailySchedule` primitive with DST-correct expansion to
  `AbsoluteScheduleValue` timelines, `GlucoseUnit` conversions, and the
  `NightscoutTimeZone` parser (handles Loop's inverted-sign `ETC/GMT±N`). 25
  unit tests green, including a spring-forward DST case.
- **2026-07-04** — Phase 2 done. Read-only `NightscoutClient` with URL
  normalization, token/api-secret auth (SHA-1 via CryptoKit), an injectable
  `NightscoutTransport` for testing, entries/treatments/profile/status
  endpoints, and lenient DTOs that tolerate Nightscout's stringy numbers,
  fractional-second timestamps, and epoch/ISO date mixing. 39 tests green.
  Deferred: devicestatus + JWT (not needed for core tuning); per-day fetch
  orchestration folds into Phase 3.
- **2026-07-04** — Third CodeRabbit pass: only 2 findings (a README typo and
  `TherapyProfile.replacing` trapping instead of throwing) — both fixed. The
  review surface is converging: 20 findings in round 1+2, 2 in round 3.
- **2026-07-04** — Phase 9 core complete; all four remaining features landed.
  (1) Multi-day chaining: `ChainedTuner` implements oref0's day-chaining model
  with 4am-local windows and pump-anchored caps; surfaced as per-hour "days
  missing" in report/JSON/app. (2) oref0 golden parity: fixtures generated from
  oref0's real JS (`tuneAllTheThings`), and the Swift tuners now match to
  ±0.001 — including oref0's rounding and smoothing quirks. (3) Swift Charts in
  the results view (validated palette, light+dark). (4) Keychain token storage
  + settings persistence. 95 tests green; CLI verified end-to-end with a
  2-day chained run.
- **2026-07-04** — Phase 8 (core) + Phase 9 (partial). Native SwiftUI macOS app
  (`TuningViewModel` + split-view form/results, ISF/CR cards, basal table, and
  disclaimer) builds and launches. Second CodeRabbit pass addressed: categorizer
  gap-state reset, COB precompute, array-length precondition, basal guardrail
  status, off-main-actor compute; kept oref0's `n*p` percentile deliberately
  (documented + test-pinned). 85 tests green.
  **State of the project:** phases 0–8 are functionally complete and the tool
  runs end-to-end (CLI + app) against a Nightscout site. Remaining work is
  refinement: multi-day chaining, golden parity fixtures, charts, and Keychain.
- **2026-07-04** — Phases 6 & 7 done. `TuningRecommendation` with Loop guardrail
  clamping, change tiers, and category/confidence context; autotune-style text
  report (with mandatory disclaimer) and JSON output. `TuningPipeline` ties
  fetch → ingest → replay → tune → recommend into one call, with an offline
  inputs path for tests. `looptune` CLI (`tune`/`fetch`) — **verified
  end-to-end against a mock Nightscout server**: 288 samples fetched, replayed,
  categorized (basal/ISF/CSF), and rendered as a recommendation. ISF correctly
  held (only 7 ISF points < 10 minimum). 84 tests green. **LoopTune is now a
  working program**, not just a library.
- **2026-07-04** — Phase 5 (single-run) done. Categorizer (CSF/UAM/basal/ISF)
  and the three tuners — per-hour basal, median-ratio ISF, and CR — with
  oref0-faithful percentile and pump-relative + per-run-step safety caps,
  orchestrated by `LoopTuner`. Notably fixed a genuine adaptation bug: the CR
  tuner must operate in carb-sensitivity space because Loop-native deviations
  are carb-model residuals, not raw carb impact (a sign test caught the naive
  port). 78 tests green. Remaining: multi-day chaining harness + oref0 parity
  fixtures.
- **2026-07-04** — Phase 4 core done, and the central thesis is now
  demonstrated: `ReplayEngine` runs history through the real LoopAlgorithm
  pipeline (annotate → insulin effects → ICE → dynamic carb absorption) and
  produces Loop-native per-interval deviations plus BGI/IOB/COB. Tests confirm
  correct behavior including Loop's 10-min insulin delay and dynamic carb
  attribution. This validates the whole architecture (OQ-1). 63 tests green.
  Also fixed a CodeRabbit pass (NaN sgv, lenient array skipping, TZ HHMM,
  target-offset guard, epsilon compare).
- **2026-07-04** — Phase 3 core done. Ingest layer: `ProfileIngest`
  (NS profile → `TherapyProfile` with unit conversion + TZ), `TreatmentIngest`
  (boluses, temp-basal effective rate + overlap trimming, suspends, carb dedupe,
  indefinite-override resolution), and `GlucoseIngest` (filter/sort/dedupe). 53
  tests green. Profile-history alignment and basal-gap filling deferred to the
  Phase 4 window builder where they're actually consumed.
