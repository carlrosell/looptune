# 0002. Verify changes at the appropriate boundary

- **Status:** Accepted
- **Date:** 2026-10-12
- **Deciders:** Project owner
- **Related:** [ADR 0001](0001-coordinate-work-through-issues-and-pull-requests.md), [Verification policy](../docs/coordination.md#verification), [Repository audit](../docs/code-reviews/2026-10-12-repository-audit-review.md)

## Context

The audit reproduced 20 defects and maintenance findings while the existing 166
tests and release build passed. A generic green test run cannot demonstrate
that a reported boundary failure is repaired. LoopTune also needs proportionate
checks for workflow documents and small maintenance changes.

## Decision

Keep macOS `swift test` as the baseline gate for runtime changes. Add focused
regression evidence for meaningful behavior changes at the affected public
boundary, including final recommendation values, temporal evidence, persistence,
requests, and app state. Use synthetic data and temporary stores.

Run a release build for executable, package, release, and cross-module changes.
Check app presentation directly when compilation and model tests cannot prove
the behavior. Validate workflow documentation, ADR links, and Python tools using
offline checks. Do not require new tests for mechanical, low-impact edits.

PRs record the verified commit, commands, outcomes, and limits. Before a merge,
the lander verifies the reviewed candidate against current main and refreshes
affected evidence when either relevant input changes. A finding becomes fixed
only after the merged repair and its verification are recorded.

## Alternatives considered

Running every possible check for every edit wastes time without covering the
reported behavior. Accepting a baseline test pass alone missed the audit's
reproductions. Importing Chatlet's performance tiers would add checks unrelated
to this package. The gate follows the affected contract instead.

## Consequences

Changes need evidence tied to the actual failure and commit. CI remains useful
but does not establish clinical validity or replace missing reproduction tests.
Reviewers must assess coverage and stale evidence, while documentation-only work
can avoid unrelated Swift runs.
