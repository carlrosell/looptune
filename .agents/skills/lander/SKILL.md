---
name: lander
description: Review, verify, and squash-merge scoped LoopTune PRs when the user explicitly asks to land them, then reconcile issues and audit evidence. Use for landing work, not for ordinary review or task coordination.
---

# Lander

Read [AGENTS.md](../../../AGENTS.md) and
[the landing workflow](../../../docs/coordination.md#landing). Act only on the
PR or set of tasks the user asked to land. A request to adopt these skills,
audit code, create issues, or review a PR is not merge authorization.

Verify the repository and active GitHub account. Read the issue, full PR diff,
review conversations, check results, and linked ADRs. Register the PR with the
host's linking tool when available. Record the current base and head SHAs.
Confirm the change satisfies the issue and that unrelated edits, credentials,
health data, and machine-local files are absent.

Review the behavior at its real boundary. For tuning changes, inspect final
values and evidence thresholds. For network and persistence changes, inspect
credential handling, identity, malformed input, compatibility, and failure
paths. Compare regression tests with the issue's reproducer. Passing existing
tests alone does not demonstrate the defect was repaired.

Verify integration with current `main` in an isolated checkout and run the
[applicable gates](../../../docs/coordination.md#verification). Do not merge
with failed or pending required checks, unresolved material review findings,
or stale evidence after relevant code changes. If another change lands first,
reassess the integration and repeat affected checks. Recheck base, head,
mergeability, and required checks immediately before merging. If either SHA
changed, refresh the review and verification; do not use an administrator bypass.

Return concrete defects to the owning worker with the affected source, trigger,
and expected behavior. Do not absorb unrelated refactors while landing. A draft
requires a readiness decision before promotion. As the authorized lander, record
that decision after verification unless the user imposed a separate restriction.
A ready PR still needs review and checks. Leave a PR open when a required
condition cannot be met and report the reason.

Squash-merge only within the authorized scope, using a Conventional Commit
title and no attribution. Where the CLI supports it, bind the merge operation
to the reviewed head SHA. Confirm the returned merged state and commit. Verify
that closing references closed the intended issues, then record the implementing
commit and verification date in the audit and update task dependencies. Preserve
the original audit evidence. Clean up only clean, task-owned branches and
worktrees after confirming their changes are in the merged result.
