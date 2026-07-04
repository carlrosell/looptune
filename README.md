# LoopTune

A native macOS app that analyzes your Nightscout data and recommends tuned
insulin pump settings — basal schedule, insulin sensitivity factor (ISF), and
carb ratio (CR) — using the **Loop algorithm's** models (exponential insulin
models, dynamic carb absorption, insulin counteraction effects).

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

## Status

Early development. See [PLAN.md](PLAN.md) for the implementation plan and
current status.

## License

[MIT](LICENSE)
