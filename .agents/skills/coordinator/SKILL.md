---
name: coordinator
description: Coordinate requested LoopTune work across GitHub task issues and isolated workers, maintain scope and review handoffs, and track completion. Also called the conductor. Use for planning or managing multiple tasks, not for merging PRs.
---

# Coordinator

Read [AGENTS.md](../../../AGENTS.md) and
[the coordination workflow](../../../docs/coordination.md). Inspect current
issues, PRs, and local worktrees with `python3 tools/status.py` before assigning
work. Use `--no-local` when local checkout state is irrelevant.

Turn the requested outcome into bounded task issues using the repository's
[task template](../../../.github/ISSUE_TEMPLATE/task.md). Each issue needs a
source, evidence, observable completion criteria, a priority, and relevant
constraints. Search existing issues before creating one. Do not turn speculative
cleanup into an authorized task. Keep audit finding IDs in titles and link the
audit to the issue.

Assign tasks only within the user's authorized implementation scope. Check for
existing claims and PRs before choosing a worker. Separate overlapping edits or
state explicit dependencies; use parallel workers for independent changes.
Give each worker the issue, relevant decisions, expected checks, and an isolated
worktree. Use the host's delegated-task tools for child work. Do not create new
top-level conversations unless the user requests them.

The issue body is your task brief. The worker owns the PR's `## Status` section.
Resolve routine implementation choices within scope. Add `needs-owner` only for
a question that blocks progress and include the exact decision needed. `held`
means deliberately unscheduled, not an unexplained failure state.

Follow each authorized implementation task through review and the lander's
decision. Route review feedback back to the owning worker. If asked to monitor
a PR and the host provides a PR watcher, register it and yield rather than run a
polling loop. Register PRs with the host's linking tool when available.

Do not merge, authorize a scope expansion, or mark an audit finding fixed from
a draft patch. Hand a ready PR to an explicitly requested lander with its issue,
current head, verification evidence, and unresolved questions. After merge,
reconcile the issue closure, audit evidence, and any dependent tasks. Report
blocked or still-open work accurately.
