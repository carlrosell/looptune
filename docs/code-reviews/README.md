# Code review archive

This directory stores completed, repository-wide code review records so their
scope, findings, fixes, and verification evidence remain available after the
implementation changes are merged.

## Naming convention

Use `YYYY-MM-DD-<scope>-review.<ext>`, where the date is when the review began
and the scope is specific enough to distinguish concurrent reviews. Keep each
report self-contained and preserve historical results; append a dated note when
the report itself is relocated or otherwise maintained.

## Reviews

- [2026-07-25 whole-application review](2026-07-25-whole-application-review.html)
  — adversarial file-by-file audit of the macOS app, CLI, tuning library,
  tests, fixtures, build configuration, scripts, and documentation. It records
  15 fixed findings and the final verification evidence.

These engineering records are not clinical validation or medical advice.
