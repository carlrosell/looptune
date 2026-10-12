# LoopTune working instructions

## Repository

LoopTune is a Swift package with a macOS app, CLI, and reusable analysis library.
Read [README.md](README.md) for commands and [PLAN.md](PLAN.md) for the product
design. Source boundaries are `Sources/LoopTuneKit`, `Sources/LoopTuneApp`, and
`Sources/LoopTuneCLI`; corresponding tests live under `Tests/`.

Preserve unrelated work. Never commit real health data, credentials, authentication
state, chat history, or machine-local caches. Use synthetic data and temporary
storage for reproductions. Nightscout access remains read-only. Changes to tuning
math need evidence about the recommendation actually returned to the caller.

Use GitHub repository `carlrosell/looptune` and account `carlrosell`. Check the
active account before external writes. Every commit uses Conventional Commits.
Do not add agent attribution to commits, PRs, issues, comments, or documentation.

## Coordination

The canonical skills live in `.agents/skills/`. `.claude/skills` links to the same
directory, and `CLAUDE.md` imports this file. Read the relevant skill when working
in one of these roles:

- [coordinator](.agents/skills/coordinator/SKILL.md), also called the conductor,
  decomposes requested work, maintains task issues, assigns workers, and follows
  review through closure.
- [worker](.agents/skills/worker/SKILL.md) implements one assigned task in its own
  worktree, verifies it, and hands off its PR.
- [lander](.agents/skills/lander/SKILL.md) reviews and merges PRs when explicitly
  asked to land work. Coordinators and workers do not merge.

Follow [docs/coordination.md](docs/coordination.md) for task states, issue and PR
ownership, claims, handoffs, and merge requirements. The workflow does not expand
the user's scope. An audit or request to create tracking issues does not start
remediation or authorize merges. Small direct tasks can be completed without
inventing an issue or a multi-worker workflow.

GitHub issues and PRs hold live work state. Read it with
`python3 tools/status.py --no-local`; use `python3 tools/status.py` to include
local worktrees. Do not maintain a second live task board in a repository file.

## Decisions and evidence

Record durable architectural and workflow decisions in [adr/](adr/README.md).
Reserve a number in the owning issue before writing an ADR; discover the next
candidate with `python3 tools/status.py --next-adr`. Defects belong in issues,
not one ADR per bug. Update [PLAN.md](PLAN.md) when product design or phase status
changes and append to its status log when work lands.

The [2026-10-12 audit](docs/code-reviews/2026-10-12-repository-audit-review.md)
holds stable finding IDs, baseline evidence, and remediation links. A finding
remains open until its fix is merged and the implementing commit, verification,
and date are recorded. Keep historical evidence intact.

## Verification

Use the [verification policy](docs/coordination.md#verification). Swift behavior
changes require focused regression evidence where meaningful and `swift test`.
Changes affecting executable integration or release behavior also need
`swift build -c release`. App changes need a targeted UI check when compilation
and unit tests cannot establish the result.

For workflow documentation and tools, run:

```sh
python3 tools/docs_check.py
python3 -m unittest discover -s tools/tests -p 'test_*.py'
```

Record commands, outcomes, and the verified commit in the PR. Do not run clinical
experiments or use real credentials to validate a code change.
