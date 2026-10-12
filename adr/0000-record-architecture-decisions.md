# 0000. Record architecture decisions

- **Status:** Accepted
- **Date:** 2026-10-12
- **Deciders:** Project owner
- **Related:** [Coordination workflow](../docs/coordination.md), [ADR index](README.md)

## Context

LoopTune already has a product plan and completed review records. The full audit
adds 20 findings whose fixes may establish new data and recommendation contracts.
The owner requested Chatlet's coordination and ADR pattern so task status and
the reasoning behind decisions remain traceable.

## Decision

Store numbered Markdown ADRs under `adr/`, with an ordered index and template.
Use issues for defects and PRs for implementations. Write an ADR when a choice
changes a durable contract or workflow, and link it to the relevant issue and PR.
Reserve numbers in open task issues before concurrent work starts.

Accepted decisions preserve their original context and reasoning. A later choice
supersedes an earlier record through a new ADR. Routine fixes do not require an
ADR if they restore an already documented contract.

## Alternatives considered

Keeping all decisions in PLAN.md would mix historical reasoning with the current
product design. One ADR per finding would duplicate the issue tracker and imply
that a defect itself is an architectural decision. Both are avoided.

## Consequences

The repository gains durable decision history without a second task queue.
Contributors must maintain the index and links. The documentation check verifies
record numbering and index coverage; review establishes whether the decision is
supported by evidence.
