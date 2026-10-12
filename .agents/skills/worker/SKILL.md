---
name: worker
description: Implement one assigned LoopTune task in an isolated worktree, add proportionate verification, and hand off a ready PR with traceable issue and decision links. Use when acting on a scoped task; does not authorize merging.
---

# Worker

Read [AGENTS.md](../../../AGENTS.md), the assigned issue, and relevant
[coordination rules](../../../docs/coordination.md). Confirm the task remains
open and unclaimed, or that the coordinator assigned its existing claim to you.
Do not start remediation just because an audit issue exists.

Claim authorized work by assigning the issue to the implementation owner and
commenting with the branch name and work scope. Check again for an existing PR
or another claim before starting. Multiple workers using the same account must
distinguish their claims by branch. Work in an isolated checkout based on the
agreed base. Preserve user changes and do not use an empty commit or draft PR
as a claim.

Reproduce the defect before changing behavior when feasible. Inspect the caller
and the returned recommendation, persisted record, request, or UI that carries
the effect. Keep shared parsing, identity, schedule, and recommendation contracts
consistent across library, CLI, and app boundaries. Use synthetic inputs and
temporary stores. Add focused regression coverage for meaningful failures;
ordinary cleanup does not require tests that mirror the implementation.

When a fix changes a durable contract, reserve a number and write an
[ADR](../../../adr/README.md) with the task. Do not use an ADR as a bug report.
Coordinate overlapping files and contract changes before expanding the patch.
If a missing decision blocks the task, ask the coordinator with evidence and
the smallest concrete choice required.

Run the [applicable checks](../../../docs/coordination.md#verification). Commit
using Conventional Commits. Open a ready PR by default; use a draft only when
the user explicitly requested one. Use the
[PR template](../../../.github/pull_request_template.md), include `Closes #N`,
and maintain `## Status` with Done, Next, Blocked, and verification evidence for
the current head. Use `State: complete` only when implementation and required
checks are complete. Do not imply a draft has been merged.

Link the PR with the host when that tool is available. Keep the audit's baseline
evidence and add the PR plus pending verification without marking the finding
fixed before merge. Respond to review and refresh affected checks after changes.
Hand the issue, PR, commit, commands, and remaining risks to the coordinator or
lander. Never merge. Clean up only task-owned, clean worktrees after the merge
has been verified, using the host's worktree lifecycle when it owns the checkout.
