# Architecture decision records

ADRs explain durable architecture and workflow decisions. Tasks and defects live
in GitHub issues; implementation progress lives in PRs. Use the
[coordination workflow](../docs/coordination.md) to connect them.

## Writing a decision

Use [template.md](template.md) for a decision that changes module boundaries,
data contracts, recommendation invariants, persistence compatibility, dependency
policy, or the development workflow. A bug fix that restores an existing contract
usually needs only its issue and verification evidence.

Run `python3 tools/status.py --next-adr`, then reserve the candidate in the owning
issue body as `Reserves: ADR NNNN`. Recheck open reservations before writing;
number discovery is not an atomic allocation. Use a zero-padded number and a
short filename, for example `0003-canonical-site-identity.md`.

Write the context, decision, alternatives, consequences, and links to the owning
issue and PR. Use status `Proposed` while a choice is unresolved. Acceptance of
the implementation or explicit agreement to the decision makes it `Accepted`.
Do not present a speculative remediation design as an accepted decision.

Once accepted, preserve the reasoning. Correct factual errors explicitly; replace
a changed decision with a new ADR and mark the old one `Superseded by` its link.
Use `Rejected` for a considered choice that will not be adopted. Add each record
to the ordered index below and run `python3 tools/docs_check.py`.

The initial workflow records were allocated together during adoption. Future
concurrent work uses issue reservations. Existing product decisions in
[PLAN.md](../PLAN.md) remain historical context; this adoption does not invent
retroactive approvals for them.

## Index

| ADR | Decision | Status |
| --- | --- | --- |
| [0000](0000-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0001](0001-coordinate-work-through-issues-and-pull-requests.md) | Coordinate work through issues and pull requests | Accepted |
| [0002](0002-verify-changes-at-the-appropriate-boundary.md) | Verify changes at the appropriate boundary | Accepted |
| [0003](0003-canonical-site-origin.md) | Identify sites by canonical origin | Accepted |
| [0004](0004-historical-replay-context.md) | Replay inputs with the settings recorded at their start | Accepted |
| [0005](0005-complete-nightscout-fetches.md) | Fetch complete Nightscout records or fail | Accepted |
| [0006](0006-same-origin-redirects.md) | Follow redirects only within the request's origin | Accepted |
| [0007](0007-measure-tuning-evidence-by-cgm-duration.md) | Measure tuning evidence by CGM duration | Accepted |
| [0008](0008-carb-retention-bound.md) | Bound carb absorption time and derive replay retention from it | Accepted |
| [0009](0009-url-user-information.md) | Remove URL user information from site addresses | Accepted |
| [0010](0010-controlled-error-messages.md) | Show errors only through controlled messages | Accepted |
