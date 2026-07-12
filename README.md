# LoopTune

A native macOS app (and CLI) that analyzes your Nightscout data and recommends
tuned insulin pump settings — basal schedule, insulin sensitivity factor (ISF),
and carb ratio (CR) — using the **Loop algorithm's** own models (exponential
insulin models, dynamic carb absorption, insulin counteraction effects).

LoopTune is to [Loop](https://loopkit.github.io/loopdocs/) what
[nighttune](https://github.com/houthacker/nighttune) /
[AutotuneWeb](https://github.com/MarkMpn/AutotuneWeb) are to OpenAPS/oref0:
it replays your historical CGM, insulin, and carb data through the algorithm's
own physiological models and suggests settings that better explain what
actually happened.

> ⚠️ **Medical disclaimer**
>
> LoopTune is an experimental analysis tool. It is **not** a medical device
> and its output is **not** medical advice. Never apply recommended settings
> blindly — review every suggestion with your diabetes care team, change one
> setting at a time, and monitor closely. Use entirely at your own risk.

## Why a Loop-specific tool?

oref0 autotune's output is not valid for Loop users: the two systems use
different insulin models (Loop's 6-hour exponential curve vs oref0's 5-hour DIA)
and define ISF differently, so a Loop ISF is typically 2–3× the equivalent
oref0 correction factor. LoopTune computes glucose *deviations* using the **real
[LoopKit `LoopAlgorithm`](https://github.com/LoopKit/LoopAlgorithm) package** —
Loop's exact models — and layers an autotune-style tuning pass on top, so the
recommendations are expressed in Loop's own terms.

See [PLAN.md](PLAN.md) for the full design, rationale, and current status.

## How it works

```
Nightscout ─▶ Ingest ─▶ Replay (LoopAlgorithm) ─▶ Tune ─▶ Recommend
   CGM,        domain     per-5-min deviations      basal/    guardrail-clamped
   insulin,    model      = observed − modeled       ISF/CR    suggestions with
   carbs,                 insulin − modeled carbs     tuners    change tiers
   profile
```

Windows longer than one day are tuned with **day-by-day chaining** (oref0's
model): each day's tuned profile seeds the next day's replay, while your pump
profile stays fixed as the safety-cap baseline, so recommendations can never
drift beyond ±20–30% of your actual settings no matter how many days are
analyzed. Per-hour **"days missing"** counts show how much real data sits
behind each basal hour.

## Validation status

The tuning math is pinned to the reference implementation by **golden parity
fixtures**: the ISF and basal tuners reproduce the output of oref0's real
`autotune` JavaScript (run via node against crafted inputs) to within 0.001,
including its rounding and smoothing quirks. The forward model is the
unmodified LoopKit `LoopAlgorithm` package. That said, **LoopTune as a whole
has not been clinically validated** — parity with reference code is an
engineering guarantee, not a medical one.

## Usage

### CLI

```sh
swift build
.build/debug/looptune tune https://your-site.example.com --days 7 --insulin novolog
# --token <access-token> for private sites
# --units mmol   (or mgdl; default "auto" uses your site's own unit)
# --json         for machine-readable output
```

`looptune fetch <url>` prints a diagnostic summary (sample counts, timezone,
units, auth status) without tuning.

Fetched days are cached locally (`~/Library/Application Support/LoopTune/DayCache`,
one JSON file per site and UTC day). A day is cached once it has been over for
24 hours — Loop edits treatments retroactively for about a day — and cached
days older than 30 days are deleted automatically. Pass `--no-cache` to bypass
the cache; delete the directory to reset it.

### App

```sh
swift run LoopTuneApp
```

Enter your Nightscout URL, choose a window and insulin type, and click Analyze.
The results view shows ISF/CR cards, a pump-vs-tuned basal chart, a per-hour
data-coverage chart, and the full basal table with days-missing confidence,
plus an mg/dL ↔ mmol/L toggle (defaults to your site's unit). Your access token
is stored in the login Keychain; the URL and options are remembered between
launches.

## Development

- `swift build` / `swift test` (120+ tests)
- `scripts/dev.sh` — watch mode: rebuilds and relaunches the app on every
  save (the app restores its state on launch, so a relaunch is nearly free);
  pass `release` for an optimized build
- For real workloads build with optimizations: `swift run -c release LoopTuneApp`
  (debug builds are 5–10× slower on the replay math)
- Depends on `LoopKit/LoopAlgorithm` (pinned by revision — the repo has no tags)
- Reference repos and research notes live under `references/` (gitignored)

## License

[MIT](LICENSE)
