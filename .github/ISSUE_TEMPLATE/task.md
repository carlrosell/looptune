---
name: Task
about: A scoped change with a source, evidence, and completion criteria
title: ""
labels: task
---

## Goal

Describe the observable outcome.

## Source

Link the request, audit finding, regression, or accepted decision that warrants
this work. Include the finding ID and baseline when applicable.

## Brief

State current behavior, trigger or reproduction, expected behavior, and affected
code. Include enough evidence for a worker to start without the original chat.

## Done when

- [ ] The reported behavior is corrected and verified at its public boundary.
- [ ] Applicable checks pass and the PR records the verified commit and commands.
- [ ] Relevant documentation and audit tracking reflect the result.

## Constraints

Record compatibility, scope limits, overlapping work, and actual dependencies.
Select one priority label: `p1`, `p2`, or `p3`. Add an ADR reservation only when a
decision record is needed, using `Reserves: ADR NNNN` after checking the next number.
