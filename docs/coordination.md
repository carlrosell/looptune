# Coordinating LoopTune work

This workflow adapts Chatlet's coordinator, worker, and lander roles to LoopTune.
The coordinator is also called the conductor. GitHub issues describe tasks,
PRs carry implementation state, and [ADRs](../adr/README.md) explain decisions.
The [audit](code-reviews/2026-10-12-repository-audit-review.md) preserves finding
evidence and links to remediation. It is not a second live task queue.

The adopted source is [Chatlet at 6494f25](https://github.com/withaspoon/chatlet/tree/6494f25fd2aa8966a64207f38dd6edb213a68aff/.agents/skills).
[ADR 0001](../adr/0001-coordinate-work-through-issues-and-pull-requests.md)
records the adaptations, including ready PRs by default and branch-based claims.

## Roles and ownership

| Role | Owns | Handoff |
| --- | --- | --- |
| [Coordinator](../.agents/skills/coordinator/SKILL.md) | Task scope, issue body, priority, dependencies, assignment | Scoped issue to a worker; ready PR to a lander |
| [Worker](../.agents/skills/worker/SKILL.md) | One task's branch, implementation, PR body and `## Status`, verification | Reviewed candidate with evidence |
| [Lander](../.agents/skills/lander/SKILL.md) | Final review, integration verification, authorized merge, closure reconciliation | Merged commit or concrete work returned to the worker |

Only the lander merges, and only when the user has asked to land that work.
Coordinating a backlog does not authorize implementing it. Creating issues and
adopting this workflow does not authorize starting fixes. Direct, bounded work
can proceed without creating tasks solely for ceremony.

The coordinator edits the task brief; a worker requests scope corrections there
through comments. A worker may add or update only its ADR reservation line in
the issue body after checking for competing reservations. The worker maintains
the PR body; reviewers leave comments
instead of overwriting it. The lander records the final merge evidence. Do not
copy chat history or add an agent signature to these records.

## Reading state

```sh
python3 tools/status.py             # GitHub state plus local worktrees
python3 tools/status.py --no-local  # GitHub state only
python3 tools/status.py --json      # Machine-readable snapshot
python3 tools/status.py --next-adr  # Next unallocated decision number
```

The tool reads `carlrosell/looptune` using `gh` authenticated as `carlrosell`.
It makes no changes. It must report access failures rather than treating them
as an empty backlog. It does not fetch branches, poll, or start workers.

| Task state | Evidence |
| --- | --- |
| Needs owner | Open issue with `needs-owner` and a concrete blocking question |
| Held | Open issue with `held`, deliberately unscheduled |
| Ready | Open `task` issue with no assignee or linked open PR |
| Running | Claimed issue with an assignee, or linked draft PR |
| Review | Linked ready PR, or a draft whose `## Status` explicitly says `State: complete` |
| Closed | Issue closed; inspect the closing PR and reason before treating it as a completed fix |

Live assignment and PR state take precedence over stale prose. An assigned task
is not ready for another worker just because its PR is not open yet. An abandoned
claim must be released explicitly. A closed issue may be declined or duplicated;
only a verified merged repair closes an audit finding as fixed.

## Task issues and priorities

Use the [task template](../.github/ISSUE_TEMPLATE/task.md). Give every task a
goal, source, brief, completion criteria, and constraints. Audit tasks use
`[SEC-01]`-style IDs in titles so the evidence remains traceable. Link source
locations to a commit when their meaning depends on a reviewed baseline.

Each `task` has exactly one priority:

- `p1`: repair first, including credential boundaries, mixed site data, incomplete
  analysis inputs, and broken recommendation limits.
- `p2`: correctness and reliability work after the highest-priority defects.
- `p3`: bounded cleanup, library hardening, and documentation reproducibility.

Initial audit priorities map high to `p1`, medium to `p2`, and low to `p3`.
Reprioritization needs a reason in the issue; it does not rewrite audit severity.
Use `security`, `architecture`, `bug`, and `documentation` as useful categories.
Use `held` for planned deferral and `needs-owner` for a blocking decision with an
explicit question. A temporary cross-task announcement can use `notice`; close
it after the affected workers have incorporated it. Durable rules belong in
docs or an ADR.

Record actual dependencies in the issue. Two tasks touching the same file need
coordination, but are not automatically dependent. Start with the audit's
[fix order](code-reviews/2026-10-12-repository-audit-review.md#fix-order) and
separate shared contracts before dispatching overlapping implementation work.

## Starting and handing off work

1. Confirm implementation is authorized. Read the task, relevant ADRs, current
   PRs, and existing claims.
2. Assign the task to the implementation owner and comment with the branch name
   and scope. When workers share one GitHub account, the branch distinguishes
   their claims. Check for a competing claim before editing.
3. Use an isolated worktree based on the agreed base. Use the host's delegated
   child-task and worktree tools when provided. New top-level conversations need
   a user request; they are not a substitute for delegation.
4. Implement the bounded change and verify it at the affected boundary. Reserve
   an ADR number only if a decision needs recording.
5. Commit using Conventional Commits and open a ready PR using the
   [PR template](../.github/pull_request_template.md). Drafts require an explicit
   user request. An empty commit or a draft PR is not needed to claim a task.
6. Include `Closes #N`, the finding ID, relevant decisions, and verification
   evidence. Maintain Done, Next, Blocked, and State in `## Status`. Set
   `State: complete` when the implementation and applicable checks are done.
7. Respond to review and refresh evidence for changed code. Hand the ready PR
   to the lander within the user's authorized scope.

Use the host's PR linking tool when available. For an explicit monitoring request,
use its PR watcher and yield. Do not install a background poller or recurring
task as part of routine coordination.

## Verification

[ADR 0002](../adr/0002-verify-changes-at-the-appropriate-boundary.md) records this
policy. Gates depend on the changed behavior, not the size of the diff.

| Change | Required evidence |
| --- | --- |
| Markdown, skills, ADRs, templates | `python3 tools/docs_check.py`; inspect instructions and links |
| Python workflow tools | `python3 -m unittest discover -s tools/tests -p 'test_*.py'`; read-only smoke check for affected CLI paths |
| Swift runtime behavior | Focused regression where meaningful; `swift test` on macOS |
| Executable, package, release, or cross-module integration | Relevant tests plus `swift build -c release` |
| App presentation or async state | Relevant tests plus targeted manual or rendered UI checks that demonstrate the changed behavior |
| Tuning, replay, schedules, or guardrails | Deterministic synthetic cases and assertions on final recommendations, evidence duration, or historical boundaries as applicable |

Document the verified commit, commands, results, and any unavailable checks.
CI is a baseline build, test, and workflow check. Passing CI does not replace a
missing task-specific reproduction. Do not add repetitive tests for mechanical
cleanup or rerun unaffected suites without a reason. Use temporary cache/history
directories and synthetic credentials. Keep real health records out of fixtures.

## Landing

The lander reads the task, diff, review comments, and current check results.
Verify the candidate with current `main` in an isolated checkout. Record both
head and base SHAs and resolve material review findings before merging. Recheck
the base and head immediately before the merge; changes invalidate affected
evidence. Required checks must have passed. Never bypass repository protections.

Use squash merge with a Conventional Commit title. Bind the operation to the
reviewed head SHA when supported. Verify the returned merged state and commit,
then confirm the intended issues closed. A merge conflict or failed check goes
back to the worker with a concrete explanation. Do not mark a task finished from
an attempted merge alone.

Record the merged commit, verification command or scenario, and date against the
audit finding. The worker can prepare the evidence in its fix PR, but the finding
remains open until the merge is confirmed. If closure evidence needs a follow-up
docs commit, include it in the authorized landing work. Keep the original trigger
and baseline intact. Update affected decisions, dependencies, and product status.

Remove only clean, task-owned worktrees and branches whose changes are verified
in the merged result. Preserve user work and shared checkouts. Use the host's
worktree lifecycle for host-owned checkouts; never force-remove them to make a
cleanup command succeed.
