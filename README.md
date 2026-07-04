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

## Usage

### CLI

```sh
swift build
.build/debug/looptune tune https://your-site.example.com --days 7 --insulin novolog
# add --token <access-token> for private sites, or --json for machine output
```

`looptune fetch <url>` prints a diagnostic summary (sample counts, timezone,
units, auth status) without tuning.

### App

```sh
swift run LoopTuneApp
```

Enter your Nightscout URL, choose a window and insulin type, and click Analyze.

## Development

- `swift build` / `swift test` (84+ tests)
- Depends on `LoopKit/LoopAlgorithm` (pinned by revision — the repo has no tags)
- Reference repos and research notes live under `references/` (gitignored)

## License

[MIT](LICENSE)
