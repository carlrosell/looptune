# 0001. Coordinate work through issues and pull requests

- **Status:** Accepted
- **Date:** 2026-10-12
- **Deciders:** Project owner
- **Related:** [ADR 0000](0000-record-architecture-decisions.md), [Coordination workflow](../docs/coordination.md), [Chatlet source](https://github.com/withaspoon/chatlet/tree/6494f25fd2aa8966a64207f38dd6edb213a68aff/.agents/skills)

## Context

The owner requested the conductor and lander pattern used in Chatlet. That repo
names the conductor `coordinator` and also has a `worker` role. LoopTune needs
the same division of task planning, implementation, and landing, adapted to its
Swift package and the owner's existing ready-PR convention.

## Decision

Keep canonical `coordinator`, `worker`, and `lander` skills under
`.agents/skills/`, with `.claude/skills` linking to that directory. AGENTS.md
routes to the skills and shared coordination documentation; CLAUDE.md imports it.

GitHub task issues hold scope, priority, assignment, and dependencies. Workers
claim authorized tasks through assignment and a branch-naming comment before
opening a PR. The coordinator owns issue briefs, workers own PR status, and an
explicitly requested lander reviews and merges. No role starts implementation
or merges merely because an audit issue exists.

Ready PRs are the default. Drafts require an explicit request. This differs from
Chatlet's draft-PR claim convention and preserves the owner's existing workflow.
All commits, including squash commits, use Conventional Commits. Records contain
no agent attribution. Host-owned delegation, PR linking, and worktree lifecycle
remain in the host when those tools are available.

`tools/status.py` derives a read-only view from GitHub and local git worktrees.
The audit keeps evidence and issue links, not live scheduling state. Defects
receive one issue each; new architectural choices receive ADRs when decided.

## Alternatives considered

Copying Chatlet's entire workflow would import its build system, machine cleanup,
worker limits, model choices, and draft conventions. A separate conductor alias
skill would duplicate coordinator instructions. A manually maintained task file
would conflict with GitHub state. The shared structure is retained without those
project-specific rules.

## Consequences

Task ownership and merge authority are explicit. Branch-naming claims distinguish
workers that share one GitHub account. Reading current status requires `gh` access
as `carlrosell`; failures must be visible. The roles and documentation add upkeep,
so small direct tasks can remain direct.
