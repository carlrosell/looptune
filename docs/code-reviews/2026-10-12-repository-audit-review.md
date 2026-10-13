# LoopTune repository audit

Started and completed 2026-10-12. Audited baseline: `e14a57c`.

The audit found 20 confirmed issues: 7 high, 10 medium, and 3 low. All remain
open. The highest priorities are final recommendation limits, behavior after
profile changes, site-data isolation, complete historical inputs, and credential
transport. All 166 existing tests and the release build pass; targeted probes
reproduced failures that those tests do not cover.

This report covers security, correctness, architecture, duplication, dead code,
tests, build configuration, and documentation. It was updated as findings were
confirmed. Application code, tests, and dependency pins are unchanged. This is
an engineering audit, not clinical validation.

## Tracking conventions

Each confirmed finding receives a stable ID, severity, source location, trigger,
impact, evidence, and suggested action. Open means confirmed and not fixed.
Design candidates remain separate from confirmed defects. High severity covers
broken recommendation limits or reset guarantees, mixed site data, silently
incomplete analysis inputs, or credential exposure over network boundaries.
Medium covers narrower correctness, local disclosure, and reliability issues.
Low covers bounded library, maintenance, or documentation issues. These are
engineering priorities, not CVSS scores.

Keep finding IDs stable during remediation. For each fix, change its status
only after the repair is merged and the implementing commit, verification command
or scenario, and verification date are recorded. A planned or partially
implemented fix remains open.

Tracking update, 2026-10-12: all 20 findings now have individual GitHub issues
with reproductions, acceptance criteria, and priority labels. Use the
[coordination workflow](../coordination.md) and `python3 tools/status.py --no-local`
for live task state. [ADRs](../../adr/README.md) record decisions made during
remediation; workflow adoption has not fixed or closed any finding.

## Coverage

- [x] Inventory tracked files, repository conventions, dependencies, and prior review.
- [x] Review network access, credentials, caches, persistence, and supply chain.
- [x] Review ingest, replay, tuners, schedules, caps, and recommendation output.
- [x] Review app state, charts, result presentation, CLI, and pipeline integration.
- [x] Trace architecture, duplicated behavior, unused code, and test boundaries.
- [x] Run baseline checks and reproduce material findings.
- [x] Reconcile findings, record limitations, and prioritize follow-up work.

## Findings index

| ID | Severity | Finding | Status | Issue |
| --- | --- | --- | --- | --- |
| SEC-01 | High | [Remote hostnames can pass the plain HTTP exception](#sec-01-remote-hostnames-can-pass-the-plain-http-exception) | Fixed | [#4](https://github.com/carlrosell/looptune/issues/4) |
| SEC-03 | High | [Cross-origin redirects forward the API secret](#sec-03-cross-origin-redirects-forward-the-api-secret) | Fixed | [#6](https://github.com/carlrosell/looptune/issues/6) |
| DATA-01 | High | [Cache keys mix sites hosted on different ports](#data-01-cache-keys-mix-sites-hosted-on-different-ports) | Fixed | [#8](https://github.com/carlrosell/looptune/issues/8) |
| DATA-04 | High | [Fixed fetch limits silently truncate records and profile history](#data-04-fixed-fetch-limits-silently-truncate-records-and-profile-history) | Fixed | [#11](https://github.com/carlrosell/looptune/issues/11) |
| CORE-01 | High | [No-evidence parameter paths bypass pump-relative caps](#core-01-no-evidence-parameter-paths-bypass-pump-relative-caps) | Fixed | [#12](https://github.com/carlrosell/looptune/issues/12) |
| CORE-02 | High | [Final basal rounding and minimums can exceed the tuning limits](#core-02-final-basal-rounding-and-minimums-can-exceed-the-tuning-limits) | Fixed | [#13](https://github.com/carlrosell/looptune/issues/13) |
| CORE-04 | High | [A final settings change can leave the previous recommendation active](#core-04-a-final-settings-change-can-leave-the-previous-recommendation-active) | Fixed | [#15](https://github.com/carlrosell/looptune/issues/15) |
| SEC-02 | Medium | [URL user information survives sanitization](#sec-02-url-user-information-survives-sanitization) | Fixed | [#5](https://github.com/carlrosell/looptune/issues/5) |
| SEC-04 | Medium | [Network error messages expose query tokens](#sec-04-network-error-messages-expose-query-tokens) | Open | [#7](https://github.com/carlrosell/looptune/issues/7) |
| DATA-02 | Medium | [Corrupt legacy schedule offsets can crash history loading](#data-02-corrupt-legacy-schedule-offsets-can-crash-history-loading) | Fixed | [#9](https://github.com/carlrosell/looptune/issues/9) |
| DATA-03 | Medium | [Oversized remote timestamps crash cache encoding](#data-03-oversized-remote-timestamps-crash-cache-encoding) | Fixed | [#10](https://github.com/carlrosell/looptune/issues/10) |
| CORE-03 | Medium | [Expanded schedules disagree with clock lookup during fall-back](#core-03-expanded-schedules-disagree-with-clock-lookup-during-fall-back) | Fixed | [#14](https://github.com/carlrosell/looptune/issues/14) |
| CORE-05 | Medium | [CGM cadence changes tuning weight and the minimum evidence duration](#core-05-cgm-cadence-changes-tuning-weight-and-the-minimum-evidence-duration) | Fixed | [#16](https://github.com/carlrosell/looptune/issues/16) |
| CORE-06 | Medium | [Profile changes reinterpret doses from before activation](#core-06-profile-changes-reinterpret-doses-from-before-activation) | Fixed | [#17](https://github.com/carlrosell/looptune/issues/17) |
| CORE-07 | Medium | [Fixed carb lookback drops meals still active in the model](#core-07-fixed-carb-lookback-drops-meals-still-active-in-the-model) | Fixed | [#18](https://github.com/carlrosell/looptune/issues/18) |
| APP-01 | Medium | [Run completion persists settings edited after the run started](#app-01-run-completion-persists-settings-edited-after-the-run-started) | Fixed | [#19](https://github.com/carlrosell/looptune/issues/19) |
| APP-02 | Medium | [Saved results do not identify their source site](#app-02-saved-results-do-not-identify-their-source-site) | Fixed | [#20](https://github.com/carlrosell/looptune/issues/20) |
| ARC-01 | Low | [An unused connection form duplicates the live sidebar](#arc-01-an-unused-connection-form-duplicates-the-live-sidebar) | Fixed | [#21](https://github.com/carlrosell/looptune/issues/21) |
| ARC-02 | Low | [Public recommendation construction can trap on short hourly arrays](#arc-02-public-recommendation-construction-can-trap-on-short-hourly-arrays) | Fixed | [#22](https://github.com/carlrosell/looptune/issues/22) |
| DOC-01 | Low | [Golden fixtures cannot be regenerated from a clean clone](#doc-01-golden-fixtures-cannot-be-regenerated-from-a-clean-clone) | Fixed | [#23](https://github.com/carlrosell/looptune/issues/23) |

## Fix order

1. Correct final recommendation invariants and reset behavior: CORE-01,
   CORE-02, CORE-04. Validate the exact values shown, exported, and replayed.
2. Isolate sites and enforce authenticated transport: DATA-01, SEC-01,
   SEC-03. Include existing cache invalidation in the site-identity change.
3. Establish complete and correctly timed evidence: DATA-04, CORE-03,
   CORE-05, CORE-06, CORE-07.
4. Fix credential disclosure, malformed-data crashes, and result context:
   SEC-02, SEC-04, DATA-02, DATA-03, APP-01, APP-02.
5. Remove dead code, repair the library boundary, and restore fixture
   reproducibility: ARC-01, ARC-02, DOC-01.

## Confirmed findings

### SEC-01 Remote hostnames can pass the plain HTTP exception

Severity: high. Status: fixed.

Tracking: [#4](https://github.com/carlrosell/looptune/issues/4).

Fixed 2026-10-12 in [#25](https://github.com/carlrosell/looptune/pull/25),
commit `ccefc07` (`ccefc070d7070b8a7a8b0c5b98eeca214b665fcf`). Plain HTTP is now
accepted only for `localhost`, canonical dotted-quad 127.0.0.0/8 literals, and
the bracketed IPv6 loopback. `NightscoutClientLoopbackTests` fail on 97f0ab2 (7
tests, 19 issues: `http://127.remote.example.com` and malformed IPv4 accepted,
`http://[::1]:1337` rejected) and pass on the merged change, including no
request for a rejected token-bearing URL through either initializer. `swift
test` and `python3 tools/docs_check.py` passed. Redirect targets remain open
under SEC-03. Integration verified on 2026-10-12 against `main` with the other
wave-1 changes: `swift test`, `python3 tools/docs_check.py`, the workflow tool
tests, and `swift build -c release` passed. The original evidence below is
unchanged.

[Sources/LoopTuneKit/Nightscout/NightscoutClient.swift:100](../../Sources/LoopTuneKit/Nightscout/NightscoutClient.swift#L100) accepts every hostname
starting with `127.` as loopback. An isolated executable using the actual source
accepted `http://127.remote.example.com` and attached a synthetic access token.
Such a name can resolve to a remote server, exposing credentials and health data
over HTTP. Parse loopback IP literals strictly and test remote numeric-prefix
hostnames alongside IPv4 and IPv6 loopback addresses.
The same check rejects `http://[::1]:1337` because it compares a bracketed host
against bare `::1`. Include that compatibility defect in the same fix.

### SEC-02 URL user information survives sanitization

Severity: medium. Status: fixed.

Tracking: [#5](https://github.com/carlrosell/looptune/issues/5).

Fixed 2026-10-13 in [#50](https://github.com/carlrosell/looptune/pull/50),
commit `05d06d8` (`05d06d81ca518aa144606c9986bef5da27fa7f6a`), under [ADR
0009](../../adr/0009-url-user-information.md). Both client initializers build
the base URL from the canonical `SiteOrigin`, so it never carries user
information; the SEC-01 loopback rule still checks the host as entered. The
preferences sanitizer clears user and password and refuses URLs without a site
origin, every write to the stored URL is sanitized, and restoring a previously
stored credential-bearing URL rewrites it without the secret or removes it. The
transport refuses any request or redirect URL with user information, including
an empty `@`. A lander probe with the audit's input
`https://audit-user:audit-password@example.com/path?token=audit-token#fragment`,
an encoded user name, and an empty user found user information retained by both
the client and the preference sanitizer on 375a689 and by neither on the merged
change. `URLUserInfoTests`, `CredentialStoreTests`, and
`TuningViewModelRunTests` cover the initializers, isolated UserDefaults
persistence and restoration, and the Keychain account key at save and restore.
Verified on 2026-10-13 against `main` at 375a689 with SEC-02 and DATA-02 merged
in that order: `swift test`, `python3 tools/docs_check.py`, the workflow tool
tests, and `swift build -c release` passed. The original evidence below is
unchanged.

The URL normalizers in [Sources/LoopTuneKit/Nightscout/NightscoutClient.swift:79](../../Sources/LoopTuneKit/Nightscout/NightscoutClient.swift#L79) and
[Sources/LoopTuneApp/CredentialStore.swift:97](../../Sources/LoopTuneApp/CredentialStore.swift#L97) strip path, query, and fragment but
retain the user and password fields. Isolated execution confirmed that a URL
with synthetic user information retains it in both the network base URL and
the string persisted in preferences. Reject or remove URL user information
before storing or using the URL. Add credential-bearing URL cases to both tests.

### SEC-03 Cross-origin redirects forward the API secret

Severity: high. Status: fixed.

Tracking: [#6](https://github.com/carlrosell/looptune/issues/6).

Fixed 2026-10-12 in [#33](https://github.com/carlrosell/looptune/pull/33),
commit `14337fb` (`14337fbaf618b780072f94c279066c08e595b953`), under [ADR
0006](../../adr/0006-same-origin-redirects.md). `URLSessionTransport` checks the
HTTPS or loopback transport policy before sending, and a per-task redirect
delegate follows a redirect only when its target has exactly the original
request's `SiteOrigin`; any other redirect is never requested and fails with
`NightscoutError.disallowedRedirect`. The rule applies to every request, and a
same-host `http` to `https` upgrade is refused. A lander probe with the real
transport on f388919 reproduced `cross_host_secret_received=true
redirect_fetch_completed=true`; on the merged change the same redirect is
refused before the second server is contacted. `RedirectPolicyTests` cover
cross-host and cross-port redirects with an API secret and a token, same-origin
redirects for both credentials, a two-hop chain, the upgrade, a downgrade,
remote plain-HTTP and cross-host HTTPS targets, and an initial request outside
the policy. Verified on 2026-10-12 against `main` at f388919: `swift test`
passed three times, the redirect suites passed ten consecutive runs, and
`python3 tools/docs_check.py`, the workflow tool tests, and `swift build -c
release` passed. The original evidence below is unchanged.

[Sources/LoopTuneKit/Nightscout/NightscoutClient.swift:10](../../Sources/LoopTuneKit/Nightscout/NightscoutClient.swift#L10) uses the shared URL
session without a redirect policy. A local 302 from `127.0.0.1` to `localhost`
on another port forwarded a synthetic `api-secret` header and completed the
fetch. Initial URL validation does not protect subsequent hops. Reject
cross-origin redirects for authenticated requests and enforce the transport
policy on every hop. Test redirects using the real URL session transport.

### SEC-04 Network error messages expose query tokens

Severity: medium. Status: open.

Tracking: [#7](https://github.com/carlrosell/looptune/issues/7).

[Sources/LoopTuneApp/TuningViewModel.swift:161](../../Sources/LoopTuneApp/TuningViewModel.swift#L161) formats unknown errors using
`String(describing:)`, and [Sources/LoopTuneApp/SidebarView.swift:46](../../Sources/LoopTuneApp/SidebarView.swift#L46) displays the result. A refused
local connection through the real client returned an error description
containing the synthetic token from the failing URL. Use controlled messages
for network errors and redact credential-bearing URLs in diagnostics. Verify
connection, DNS, TLS, and timeout errors without exposing token values.

### DATA-01 Cache keys mix sites hosted on different ports

Severity: high. Status: fixed.

Tracking: [#8](https://github.com/carlrosell/looptune/issues/8).

Fixed 2026-10-12 in [#28](https://github.com/carlrosell/looptune/pull/28),
commit `3667208` (`3667208328db181875bb0f20c682a8c5a7565a60`), under [ADR
0003](../../adr/0003-canonical-site-origin.md). `SiteOrigin` identifies a site
by scheme, validated host, and effective port; `NightscoutClient` sets it in
both initializers, and the day cache now lives under
`DayCache/v2/<scheme>_<host>_<port>/`. Days cached under the hostname-only
layout are never read; pruning removes only their day-named JSON files and empty
folders. On c40b778 the pipeline test `cacheIsolatedByPort` failed: the
`http://localhost:8080` client made no data requests and received the
`http://localhost:1337` site's glucose. It passes on the merged change.
`SiteOrigin` returns nil for hosts that cannot round-trip to a URL, so `url` and
`description` cannot trap; a lander probe confirmed this for encoded space,
slash, and NUL hosts, and confirmed that pruning does not follow symlinks out of
the cache root. Integration verified on 2026-10-12 against `main` at c40b778:
`swift test`, `python3 tools/docs_check.py`, the workflow tool tests, and `swift
build -c release` passed. Scheme changes on one host (SEC-03), credential
account keys (SEC-02), and saved-run provenance (APP-02) remain with their own
findings. The original evidence below is unchanged.

[Sources/LoopTuneKit/Pipeline/TuningPipeline.swift:335](../../Sources/LoopTuneKit/Pipeline/TuningPipeline.swift#L335) keys the day cache using
only `client.baseURL.host`. `http://localhost:1337` and `http://localhost:8080`
therefore reuse the same glucose and treatments even when they are different
sites. An isolated executable reproduced the collision. The pipeline still
fetches a fresh profile from the selected site, so it can combine one site's
therapy profile with another site's cached records. Use a canonical origin
identity that includes scheme, normalized host, and effective port. Version or
invalidate the existing hostname-only cache.

### DATA-02 Corrupt legacy schedule offsets can crash history loading

Severity: medium. Status: fixed.

Tracking: [#9](https://github.com/carlrosell/looptune/issues/9).

Fixed 2026-10-13 in [#43](https://github.com/carlrosell/looptune/pull/43),
commit `1bdb7d1` (`1bdb7d1207faaf6ee983f75b38472693b7216848`). Saved schedule
offsets are range-checked before conversion: `secondsSinceMidnight` must be in
[0, 86400) and legacy `startMinutes` in [0, 1440). Saved basal hours must be in
[0, 24) and cover each hour exactly once, and saved evidence counts that the
display multiplies must not overflow. Failures throw
`DecodingError.dataCorrupted`, and `RunStore.loadAll()` skips the record while
valid runs load. A lander probe on 375a689 decoded a basal hour of `Int.max`, a
23-hour schedule, and a `totalSamples` of `Int.max`; the merged change rejects
all three and still decodes the valid control. Saved diagnostics counts that
reach the same display path are tracked separately in
[#52](https://github.com/carlrosell/looptune/issues/52). Verified on 2026-10-13
against `main` at 375a689 with SEC-02 and DATA-02 merged in that order: `swift
test`, `python3 tools/docs_check.py`, the workflow tool tests, and `swift build
-c release` passed. The original evidence below is unchanged.

[Sources/LoopTuneKit/Recommend/Recommendation+Codable.swift:55](../../Sources/LoopTuneKit/Recommend/Recommendation+Codable.swift#L55) multiplies a
decoded legacy `startMinutes` integer by 60 without validation. An isolated
subprocess using the production decoder terminated with signal 5 for `Int.max`;
`-1` decoded to a negative offset. `RunStore.loadAll()` uses `try?`, which cannot
catch an arithmetic trap, and runs during app initialization. Validate offsets
before conversion and reject invalid saved schedule structures as decoding
errors. Add corrupt-history tests that exercise startup loading.

### DATA-03 Oversized remote timestamps crash cache encoding

Severity: medium. Status: fixed.

Tracking: [#10](https://github.com/carlrosell/looptune/issues/10).

Fixed 2026-10-13 in [#48](https://github.com/carlrosell/looptune/pull/48),
commit `1ba3892` (`1ba3892d6c951b0aa04915fb274ce6a6aa0f7c7c`). Nightscout
timestamps must lie between 0001-01-01 and 9999-12-31T23:59:59.999Z; numeric
epochs and ISO dates outside that range, and non-finite values, are rejected
rather than clamped, and an out-of-range numeric entry date no longer falls back
to `dateString`. Encoding an unrepresentable date throws
`EncodingError.invalidValue`, which the day cache already handles by skipping
the write, and a fetched array containing such a record fails with the
controlled `partialDecoding` error before anything is cached. With the range
checks reverted, the new `TimestampBoundsTests` and the fetch test fail on the
audit's `1e30` and `-1e30` cases. Verified on 2026-10-13 against `main` at
166ce01: `swift test`, `python3 tools/docs_check.py`, the workflow tool tests,
and `swift build -c release` passed. The original evidence below is unchanged.

[Sources/LoopTuneKit/Nightscout/LenientDecoding.swift:115](../../Sources/LoopTuneKit/Nightscout/LenientDecoding.swift#L115) accepts any finite
epoch value, but [Sources/LoopTuneKit/Nightscout/NightscoutDTOs.swift:25](../../Sources/LoopTuneKit/Nightscout/NightscoutDTOs.swift#L25) converts milliseconds to `Int` without
a range check. A synthetic entry with `date: 1e30` and `sgv: 120` decoded, then
terminated an isolated process with signal 5 during `DayCache.store`. Validate
representability on input and use a checked encoding conversion. An invalid
server response must throw, and optional caching must not turn it into a trap.

### DATA-04 Fixed fetch limits silently truncate records and profile history

Severity: high. Status: fixed.

Tracking: [#11](https://github.com/carlrosell/looptune/issues/11).

Fixed 2026-10-12 in [#36](https://github.com/carlrosell/looptune/pull/36),
commit `456941f` (`456941fdcc1b914dbf959cc3e6b3a96802a15476`), under [ADR
0005](../../adr/0005-complete-nightscout-fetches.md). Entries and treatments are
fetched per UTC day with `count=1500`; a response of 1,000 or more records is
treated as possibly capped and its date range is bisected and requeried, with
overlap duplicates removed. An unsplittable full range or more than 64 queries
per day throws `incompleteRecords`. Profile history is requested from 100 up to
3,200 documents until it covers the profile active at the earliest replay input;
a capped or count-ignoring response throws `incompleteProfileHistory`. Only
complete days are cached. On 876b5d2 an adapted copy of `CompleteFetchTests`
failed: 1,501 doses and readings were truncated to 1,500 and the 101-profile
history was not extended. With the capped-response and count-probe mitigations
disabled, five of the merged tests fail. Verified on 2026-10-12 against `main`
at a075b1c: `swift test`, `python3 tools/docs_check.py`, the workflow tool
tests, and `swift build -c release` passed. A server that caps below 1,000
records remains a documented residual risk in ADR 0005. The original evidence
below is unchanged.

[Sources/LoopTuneKit/Pipeline/TuningPipeline.swift:322](../../Sources/LoopTuneKit/Pipeline/TuningPipeline.swift#L322) requests only 100
profiles; lines 345 to 346 request only 1,500 entries and treatments per day.
There is no pagination, saturation check, or check that profile history reaches
the analysis start. A capped synthetic transport returned 1,500 of 1,501 doses
without an error. In the same run it returned 100 of 101 profiles, causing
`ProfileHistory.activeProfile` to assign basal 1.0 at a time when the missing
older profile specified 0.5. These incomplete responses can then be cached.
Page or subdivide saturated data queries and fetch the profile active before
the earliest replay input. Reject unresolved gaps rather than treating them as
complete. Test saturated responses and a missing historical baseline.

### CORE-01 No-evidence parameter paths bypass pump-relative caps

Severity: high. Status: fixed.

Tracking: [#12](https://github.com/carlrosell/looptune/issues/12).

Fixed 2026-10-12 in [#26](https://github.com/carlrosell/looptune/pull/26),
commit `e248eb2` (`e248eb2e3adc932d0082be4aef1e3fb38ce2f7ed`). No-evidence and
rejected-computation ISF and CR paths now carry the current value forward
clamped to the pump-relative caps, fall back to the pump value when the current
value is unusable, and stay untuned with their actual evidence count.
`NoEvidenceCapTests` fail on ccefc07 (23 issues; ISF 100 against cap 57.143, CR
30 against cap 12) and pass on the merged change, covering scalar and schedule
tuners, `TuningRecommendation(from:)`, and a historical-profile `TuningPipeline`
run. The tuned path still rounds to 3 dp after clamping, a documented tolerance
of 0.0005. `swift test` passed. Integration verified on 2026-10-12 against
`main` with the other wave-1 changes: `swift test`, `python3
tools/docs_check.py`, the workflow tool tests, and `swift build -c release`
passed. The original evidence below is unchanged.

[Sources/LoopTuneKit/Tune/SensitivityTuner.swift:53](../../Sources/LoopTuneKit/Tune/SensitivityTuner.swift#L53) and [Sources/LoopTuneKit/Tune/ScheduleTuners.swift:133](../../Sources/LoopTuneKit/Tune/ScheduleTuners.swift#L133) can return historical
ISF or carb-ratio values unchanged when a block lacks eligible evidence. Those
values can differ substantially from the current pump baseline. Execution of
the source reproduced ISF 100 against pump 40 with a cap of 57.143, and CR 30
against pump 10 with a cap of 12. Absolute recommendation guardrails allow these
values through. Apply a consistent current-baseline policy and caps on every
return path. Add history-change cases with no eligible block evidence.

### CORE-02 Final basal rounding and minimums can exceed the tuning limits

Severity: high. Status: fixed.

Tracking: [#13](https://github.com/carlrosell/looptune/issues/13).

Fixed 2026-10-12 in [#29](https://github.com/carlrosell/looptune/pull/29),
commit `9395a52` (`9395a52a72970c387c2a1c280c92fcc14f59ecc8`). Each basal hour
now carries a minimum and maximum rate (0.7–1.2× pump, narrowed to Loop's
0.05–30 U/hr). The recommended rate is clamped into that range and the entered
rate is the nearest in-range pump increment; when no increment fits, the pump
rate is kept, so a zero rate stays zero. Change tiers and guardrail status in
the text report, JSON, app table, and run-history headline describe the rounded
rate. On 8ee760f, pump 0.15/raw 0.18 entered 0.20 (`large`) and a zero rate
became 0.05; on the merged change they enter 0.15 (`minimal`) and 0.00.
`BasalLimitTests` cover zero, 0.15/0.18 at 0.05 and 0.025 increments, no fitting
increment, and limit-adjacent values through the struct, JSON, and text output.
Integration verified on 2026-10-12 against `main` with the other wave-1 changes:
`swift test`, `python3 tools/docs_check.py`, the workflow tool tests, and `swift
build -c release` passed, and a rendered `ResultsView` with synthetic data
showed the rounded values and tier highlighting. The original evidence below is
unchanged.

[Sources/LoopTuneKit/Recommend/Recommendation.swift:110](../../Sources/LoopTuneKit/Recommend/Recommendation.swift#L110) and
[Sources/LoopTuneKit/Recommend/LoopGuardrails.swift:19](../../Sources/LoopTuneKit/Recommend/LoopGuardrails.swift#L19) apply an absolute minimum and round after tuning caps.
Source execution reproduced a zero pump/raw rate becoming 0.05 U/hr, and a
capped raw rate of 0.18 for pump 0.15 becoming an entered rate of 0.20, a 33.3%
increase. Constrain the final pump-representable value, preserve supported zero
rates, and test small-rate boundaries against both absolute and relative limits.

### CORE-03 Expanded schedules disagree with clock lookup during fall-back

Severity: medium. Status: fixed.

Tracking: [#14](https://github.com/carlrosell/looptune/issues/14).

Fixed 2026-10-12 in [#32](https://github.com/carlrosell/looptune/pull/32),
commit `f388919` (`f388919151d1a614f7d953484472128bb1e0f66a`).
`DailySchedule.expand` now splits the window at every UTC-offset transition and
takes each segment's value from direct lookup, so a repeated local boundary
applies at both occurrences and a boundary skipped by a forward change applies
at the transition. The audit's New York 04:00Z–09:00Z window now expands to 1,
2, 1, 2, 3, and the second 01:15 gives 1 through both paths. The new
`DailySchedule` and `ReplayEngine` tests fail on 0ea1742 (140 issues) and pass
on the merged change. They compare lookup and expansion every minute and at ±1 s
around each cut for both New York transitions, both Lord Howe 30-minute
transitions, and a clipped window, and a replay case shows no insulin effect
from a scheduled-rate temp basal during the repeated hour. A lander probe found
no mismatch across 305 offset transitions in 12 time zones from 2010 through
2026. The supported domain is offset changes reported by Foundation's time zone
data. Verified on 2026-10-12 against `main` at 0ea1742: `swift test`, `python3
tools/docs_check.py`, the workflow tool tests, and `swift build -c release`
passed. The original evidence below is unchanged.

[Sources/LoopTuneKit/Model/DailySchedule.swift:110](../../Sources/LoopTuneKit/Model/DailySchedule.swift#L110) resolves only one occurrence
of repeated local schedule times and omits a cut at the daylight-saving clock
transition. With America/New_York on 2026-11-01 and rates 00:00=1, 01:30=2,
02:00=3, the second 01:15 gives 1 through direct lookup but 2 through the expanded
timeline. This changes replay inputs in affected windows. Include repeated
boundaries and the offset transition; verify timeline and direct lookup agree
through both DST transitions.

### CORE-04 A final settings change can leave the previous recommendation active

Severity: high. Status: fixed.

Tracking: [#15](https://github.com/carlrosell/looptune/issues/15).

Fixed 2026-10-12 in [#27](https://github.com/carlrosell/looptune/pull/27),
commit `8ee760f` (`8ee760fe824544172fa8a191f606f2d6b4ff894e`). `ChainedTuner`
now resets output and evidence at each therapy change, so samples, evidence
counts, untuned flags, days missing, `daysTuned`, and trajectories describe only
the final settings. The audit scenario now throws
`insufficientUsableData(minimum: 12, actual: 0)` through `TuningPipeline`; a
change at hour 12 with CGM through hour 24 equals a post-change-only run. The
new `ChainedTunerTests` suite fails on ccefc07 (11 issues) and passes on the
merged change. `excludedOverrideSamples` still counts the whole window. `swift
test` and `swift build -c release` passed. Integration verified on 2026-10-12
against `main` with the other wave-1 changes: `swift test`, `python3
tools/docs_check.py`, the workflow tool tests, and `swift build -c release`
passed. The original evidence below is unchanged.

[Sources/LoopTuneKit/Tune/ChainedTuner.swift:94](../../Sources/LoopTuneKit/Tune/ChainedTuner.swift#L94) resets `evolving` at a therapy
change but retains `lastOutput` and accumulated evidence. If fewer than 12
deviations follow the change, the segment is skipped and the previous output
becomes the final recommendation. An actual pipeline run over a 24-hour window
with old ISF 100 and CR 30, current ISF 40 and CR 10 activated at hour 23, and
CGM stopping at hour 22 returned the old values, 264 samples, and one settings
change. Reset output and applicable evidence with the therapy change; require
enough evidence for the active settings or report insufficient data. Test a
late profile change with no subsequent CGM.

### CORE-05 CGM cadence changes tuning weight and the minimum evidence duration

Severity: medium. Status: fixed.

Tracking: [#16](https://github.com/carlrosell/looptune/issues/16).

Fixed 2026-10-12 in [#34](https://github.com/carlrosell/looptune/pull/34),
commit `a1322c6` (`a1322c652c875cd60dd626d88ddd6cfba9c78b86`), under [ADR
0007](../../adr/0007-measure-tuning-evidence-by-cgm-duration.md). Each deviation
carries the duration of its CGM interval; basal sums, meal residuals, the ISF
median, and diagnostic means are weighted by it, evidence counts measure CGM
time in five-minute intervals, the minimums compare actual duration (one hour
for the pipeline and each segment, 50 minutes for ISF), and the trailing-delta
horizon spans a fixed 20 minutes. Five-minute results and the oref0 parity
fixtures are unchanged. A lander probe on 7af9ec4 with a three-hour rise gave
hour-3 basal 1.200, 1.052, and 1.027 U/h with evidence 180, 36, and 12 at 60,
300, and 900 s; the merged change gives 1.045, 1.052, and 1.070 with evidence 36
at each cadence, all entering 1.05, and rejects 12 minutes of one-minute
readings that 7af9ec4 accepted. `CadenceIndependenceTests` cover equivalence,
jitter, supported and rejected gaps, the per-block carb-ratio path, and the
single-pass and chained entry points. A rendered `ResultsView` with synthetic
data showed the evidence labels in CGM time. Verified on 2026-10-12 against
`main` at 7af9ec4: `swift test`, `python3 tools/docs_check.py`, the workflow
tool tests, and `swift build -c release` passed, and CI passed on Swift 6.1.2.
Cadence can still shift a rate by up to a few hundredths of a unit per hour
where glucose changes direction on an hour boundary, as ADR 0007 records. The
original evidence below is unchanged.

[Sources/LoopTuneKit/Replay/ReplayEngine.swift:110](../../Sources/LoopTuneKit/Replay/ReplayEngine.swift#L110) normalizes each interval to
five minutes, but [Sources/LoopTuneKit/Tune/BasalTuner.swift:45](../../Sources/LoopTuneKit/Tune/BasalTuner.swift#L45) and the meal residual calculations
sum each normalized sample with equal weight. The same three-hour rising
glucose trajectory at 60, 300, and 900-second spacing produced hour-3 basal
recommendations of 1.2, 1.117, and 1.036 respectively. A 12-minute window with
one-minute CGM also satisfied the pipeline's 12-sample threshold, documented as
one hour. Use a consistent sample grid or retain durations for aggregation and
evidence checks. Test equivalent trajectories at different sampling cadences.

### CORE-06 Profile changes reinterpret doses from before activation

Severity: medium. Status: fixed.

Tracking: [#17](https://github.com/carlrosell/looptune/issues/17).

Fixed 2026-10-12 in [#38](https://github.com/carlrosell/looptune/pull/38),
commit `a075b1c` (`a075b1cbc9f200879938c9c7f66c23b927632aa6`), under [ADR
0004](../../adr/0004-historical-replay-context.md). `TherapyTimeline` composes
recorded profile history with the candidate profile, expanding each period in
its own time zone and keeping a cut at every settings-period boundary, and
`HistoricalReplay` is the single replay context for chained tuning and
diagnostics. Inputs that began before an activation keep their recorded
settings; inputs after it, including the post-change part of a crossing temp
basal, use the candidate. The pipeline uses chained replay when a change falls
in the input lookback before the window. The audit bolus now gives -1.076170
after activation. A lander probe through `ChainedTuner` showed that on 876b5d2 a
pre-change 1 U bolus was read with the new ISF 80, while the merged change gives
exactly the result of the 0.5 U ISF-80 equivalent; a temp basal crossing an
ISF-only change matches its explicitly split equivalent (it differed by up to
1.13 mg/dL per 5 min before the fix round). `HistoricalReplayTests` cover
pre-change basal, crossing temp basals for basal-, ISF-, CR-, and combined
changes, pre-change meals, post-change boluses, target-only uploads, A to B to A
history, another time zone, and per-period insulin type. History that does not
reach the earliest input is rejected at the pipeline boundary by DATA-04.
Verified on 2026-10-12 against `main` at 876b5d2: `swift test`, `python3
tools/docs_check.py`, the workflow tool tests, and `swift build -c release`
passed. The original evidence below is unchanged.

[Sources/LoopTuneKit/Tune/ChainedTuner.swift:114](../../Sources/LoopTuneKit/Tune/ChainedTuner.swift#L114) passes one profile to replay,
and [Sources/LoopTuneKit/Replay/ReplayEngine.swift:54](../../Sources/LoopTuneKit/Replay/ReplayEngine.swift#L54) expands it over the complete input lookback.
The pinned model evaluates sensitivity at the dose start. A 1 U bolus given
under ISF 40 one hour before ISF 80 activation therefore produced a first
post-change insulin effect of -2.152340 when replayed with the new profile,
instead of -1.076170 using the recorded dose-start sensitivity. Build historical
schedule timelines across the lookback, or explicitly exclude unsupported
transition tails. Cover pre-change insulin and meals in both tuning and
diagnostics tests. Splitting the analysis at activation alone does not fix this.

### CORE-07 Fixed carb lookback drops meals still active in the model

Severity: medium. Status: fixed.

Tracking: [#18](https://github.com/carlrosell/looptune/issues/18).

Fixed 2026-10-12 in [#39](https://github.com/carlrosell/looptune/pull/39),
commit `fb5d320` (`fb5d3202da038eb9391368033eaf68f29083577a`), under [ADR
0008](../../adr/0008-carb-retention-bound.md). Entered absorption time is
bounded at the model's 10-hour maximum; a longer entry stops the analysis with a
message naming the entry, its time, and the limit. Carb and glucose retention
cover the longest modeled absorption span plus margin (15h45m) and doses reach
23h45m before a segment, while carb-ratio attribution stays at 10 hours. On the
merged change a trimmed replay of the audit case equals the full replay within
1e-9; restoring the previous 10, 10, and 18 hour lookbacks makes 8 of the 10
`CarbRetentionTests` fail with 222 issues. Diagnostics now propagate replay
errors other than insufficient glucose, and the only new one is rejected earlier
by input validation. A synthetic 14-day chained run took about 5.4 s against 4.0
s before in a debug build. Verified on 2026-10-12 against `main` at a1322c6:
`swift test`, `python3 tools/docs_check.py`, the workflow tool tests, and `swift
build -c release` passed. The original evidence below is unchanged.

[Sources/LoopTuneKit/Replay/ReplayEngine.swift:149](../../Sources/LoopTuneKit/Replay/ReplayEngine.swift#L149) assumes ten hours bounds
carbohydrate activity and drops older meals at lines 166 to 170. The pinned
model multiplies entered absorption time by 1.5 on the path used here; its
ten-hour constant does not clamp that path. A valid eight-hour meal logged
10.5 hours before the segment still produced COB 1.547497 g and deviation
-0.668724 in full replay. Trimmed replay produced zero for both. Derive retention
from model duration, including delay and overrun, or enforce a supported input
bound. Test full and trimmed replay equivalence at that boundary.

### APP-01 Run completion persists settings edited after the run started

Severity: medium. Status: fixed.

Tracking: [#19](https://github.com/carlrosell/looptune/issues/19).

Fixed 2026-10-13 in [#47](https://github.com/carlrosell/looptune/pull/47),
commit `166ce01` (`166ce011c2088acd4ceb29451ba58a05b3731471`). `run()` captures
an immutable `AnalysisRequest`; a successful run persists exactly that request
and a failed run persists nothing. The Nightscout and Analysis sidebar sections
are disabled while a run is pending, and the form URL is only rewritten if it is
unchanged. `TuningViewModelRunTests` drive runs with controlled completion; with
persistence switched back to the live form, five checks fail in the
token-clearing and settings-switching cases. Integration verified on 2026-10-13
against `main` at 9448dfb with the other wave-3 changes landed in the same
order: `swift test`, `python3 tools/docs_check.py`, the workflow tool tests, and
`swift build -c release` passed. The original evidence below is unchanged.

[Sources/LoopTuneApp/TuningViewModel.swift:94](../../Sources/LoopTuneApp/TuningViewModel.swift#L94) captures the request URL, token,
and configuration, but completion calls `persistSettings` at line 123 using
the live form fields at lines 76 to 84. The sidebar leaves those controls
editable during analysis. A controlled execution of the actual view-model
source started with site A and a token, cleared the form token while the runner
was suspended, then completed successfully and deleted the stored token. A
second case switched to site B and 30 days during a site A seven-day run; it
persisted the untested B settings while selecting the A result. Persist the
successful request snapshot and define what happens to edits made during a run,
or disable those controls until completion. Test this at the view-model boundary
with controllable completion and isolated stores.

### APP-02 Saved results do not identify their source site

Severity: medium. Status: fixed.

Tracking: [#20](https://github.com/carlrosell/looptune/issues/20).

Fixed 2026-10-13 in [#53](https://github.com/carlrosell/looptune/pull/53),
commit `17ecdc1` (`17ecdc18257aa2fbc577e9c7479d01d4e7d8edd6`). A saved run
records its canonical `SiteOrigin` as `siteOrigin`, reparsed on load so a
hand-edited value cannot add user information, a path, or a query, and still
writes `siteHost` for older builds. The result header and each history row show
the selected run's own source, truncated in the middle with the full value in
the tooltip; a legacy host-only record shows only its validated hostname and
says its scheme and port were not saved. With the recorded origin ignored, 13
checks fail across `SavedRunSourceTests` and the view-model tests, including the
two-port history selection test. A lander render of history rows with two
localhost ports, a long credential-bearing URL, and a legacy record showed
distinct ports, a middle-truncated label keeping scheme and port, and no
credentials. Verified on 2026-10-13 against `main` at 1fd84d4: `swift test`,
`python3 tools/docs_check.py`, the workflow tool tests, and `swift build -c
release` passed. The original evidence below is unchanged.

[Sources/LoopTuneKit/Persistence/SavedRun.swift:8](../../Sources/LoopTuneKit/Persistence/SavedRun.swift#L8) stores `siteHost`, but no app
view displays it. [Sources/LoopTuneApp/SidebarView.swift:95](../../Sources/LoopTuneApp/SidebarView.swift#L95) shows only the date
and change summary; [Sources/LoopTuneApp/LoopTuneApp.swift:78](../../Sources/LoopTuneApp/LoopTuneApp.swift#L78) shows only days and sample count.
Completing a run for A and then editing the URL to B leaves A's recommendation
visible beside B's connection field, without a source label. Selecting older
history has the same ambiguity and does not require the APP-01 race. Source
search and a controlled view-model execution confirmed the state. Display the
selected run's origin in the result header and history row. Verify two-site
history selection; no real-world misapplication is claimed.

### ARC-01 An unused connection form duplicates the live sidebar

Severity: low. Status: fixed.

Tracking: [#21](https://github.com/carlrosell/looptune/issues/21).

Fixed 2026-10-13 in [#46](https://github.com/carlrosell/looptune/pull/46),
commit `e3bb24a` (`e3bb24adf48a092e49629e7e836cfd82f7128201`). The unused
`ConnectionForm` view is deleted; `SidebarView` is the only connection layout,
and no source references remain. The link above now points to the file at the
audit baseline. Integration verified on 2026-10-13 against `main` at 9448dfb
with the other wave-3 changes landed in the same order: `swift test`, `python3
tools/docs_check.py`, the workflow tool tests, and `swift build -c release`
passed. The original evidence below is unchanged.

[Sources/LoopTuneApp/ConnectionForm.swift:5](https://github.com/carlrosell/looptune/blob/e14a57c5f92038ce9edbc65ac3c8f070bf642356/Sources/LoopTuneApp/ConnectionForm.swift#L5) defines an internal view with no
callers in the repository. [Sources/LoopTuneApp/LoopTuneApp.swift:39](../../Sources/LoopTuneApp/LoopTuneApp.swift#L39) uses `SidebarView`, whose
connection, analysis, and run controls duplicate the unused form. Remove the
obsolete view or share a single implementation if both layouts are needed.
Repository-wide symbol search confirmed the absence of references.

### ARC-02 Public recommendation construction can trap on short hourly arrays

Severity: low. Status: fixed.

Tracking: [#22](https://github.com/carlrosell/looptune/issues/22).

Fixed 2026-10-13 in [#44](https://github.com/carlrosell/looptune/pull/44),
commit `c6add2e` (`c6add2e592ead16569bfc5f53c8e4c07c08358ad`).
`TuningRecommendation.init(from:)` checks all five hourly collections, including
values set through public mutation and a supplied `daysMissingByHour`, and
throws `TuningOutput.HourlyCountError` instead of trapping; the throwing
`TuningOutput` initializer runs the same check. A lander exit test confirmed
that on 9448dfb an empty `basalSampleCountByHour` terminates the process.
Integration verified on 2026-10-13 against `main` at 9448dfb with the other
wave-3 changes landed in the same order: `swift test`, `python3
tools/docs_check.py`, the workflow tool tests, and `swift build -c release`
passed. The original evidence below is unchanged.

[Sources/LoopTuneKit/Tune/LoopTuner.swift:68](../../Sources/LoopTuneKit/Tune/LoopTuner.swift#L68) accepts arbitrary hourly array
lengths. The throwing recommendation initializer checks three arrays at
[Sources/LoopTuneKit/Recommend/Recommendation.swift:252](../../Sources/LoopTuneKit/Recommend/Recommendation.swift#L252), but indexes `daysMissingByHour` and
`basalSampleCountByHour` without length checks at lines 324 to 325. Passing an
empty coverage array reaches an out-of-bounds access. Current production tuners
supply 24 values, so this affects library callers and future changes. Validate
all hourly collections at their construction boundary and throw a defined
error. Actual-module subprocesses trapped with signal 5 for each empty array;
a valid 24-element control succeeded. A surrounding `do/catch` did not help.

### DOC-01 Golden fixtures cannot be regenerated from a clean clone

Severity: low. Status: fixed.

Tracking: [#23](https://github.com/carlrosell/looptune/issues/23).

Fixed 2026-10-13 in [#45](https://github.com/carlrosell/looptune/pull/45),
commit `85c3f95` (`85c3f954986693448cb3d72de6c930cf5e6c1073`).
`scripts/generate-oref0-fixtures.js` regenerates the three parity fixtures from
a disposable oref0 clone pinned to 88cf032, refuses other revisions or modified
clones, forces UTC, and has a `--check` mode; the fixture README documents the
commands and the oracle's limited basal and ISF scope. A lander spot-check from
a fresh clone matched all three fixtures under UTC and America/New_York,
regenerated them byte-for-byte unchanged, and rejected a tampered fixture.
Integration verified on 2026-10-13 against `main` at 9448dfb with the other
wave-3 changes landed in the same order: `swift test`, `python3
tools/docs_check.py`, the workflow tool tests, and `swift build -c release`
passed. The original evidence below is unchanged.

[Tests/LoopTuneKitTests/Fixtures/oref0/README.md:9](../../Tests/LoopTuneKitTests/Fixtures/oref0/README.md#L9) instructs contributors to run
`node references/gen_oref0_fixtures.js`, but that file is absent from Git and
the working tree. The complete `references/` directory is ignored. Commit the
generator under test support or `scripts/`, with instructions for obtaining the
pinned reference revision. The existing three fixture tests still run; they
establish basal and ISF examples, not carb-ratio or end-to-end replay parity.

## Architecture and duplication follow-up

The package direction is sound: the macOS app and CLI depend on `LoopTuneKit`,
and the library depends on the pinned model package. No target dependency cycle
was found. Keep that separation and the existing `NightscoutTransport` boundary.
The following changes would address concrete sources of the findings above.
They are design candidates, not additional confirmed defects or approved fixes.

1. **Give one component ownership of site identity.** The client normalizer,
   credential URL helpers, pipeline cache key, and saved-run provenance all
   describe the same site differently. This duplication contributes to SEC-01,
   SEC-02, DATA-01, and APP-02. URL parsing is an in-process dependency; Keychain,
   disk, and network are separate boundaries. Verify normalization once, then
   exercise origin isolation through storage and transport tests. Keep real
   redirect tests because a request stub does not exercise URLSession redirects.

2. **Own historical replay context in one place.** `ChainedTuner` and
   `DiagnosticsBuilder` separately combine day windows, profile segments,
   trimming, replay, and override filtering. `ReplayEngine` receives only one
   profile, so neither caller can preserve activation-aware lookback schedules.
   This is an in-process cluster with the model library. Test recorded profile
   transitions and full-versus-trimmed equivalence at a replay boundary, then
   keep tuning and diagnostics specific tests for their own output contracts.
   CORE-03, CORE-06, and CORE-07 should drive this work.

3. **Centralize schedule invariants and arithmetic.** Time-weighted averages
   recur in `DailySchedule.swift:168`, `LoopTuner.swift:170`, and
   `Recommendation.swift:349`. Clock parsing differs between
   `DailySchedule.Entry.init(time:)` at line 181 and `NSScheduleItem` at
   `NightscoutDTOs.swift:222`: the former accepts malformed seconds as zero
   and ignores extra components, while the latter rejects them. These are
   in-process dependencies. Share strict offset parsing and aggregation and
   test construction, conversion, and serialization. Do not indiscriminately
   collapse equal adjacent evidence blocks; `DailySchedule` normalization can
   remove distinctions needed by the tuning evidence model.

4. **Expose a testable app run boundary.** `TuningViewModel` injects concrete
   stores, then constructs the client, pipeline, cache, clock value, and detached
   task itself. A small injectable run service with controllable completion
   would let tests cover APP-01, failure state, run selection, and persistence
   without replacing tuning internals. This combines a true external network
   dependency with locally substitutable storage. The existing four app tests
   cover URL helper functions and chart rendering, with no run-lifecycle tests.

Dead-code searches confirmed only the unused internal `ConnectionForm` as a
removal candidate. Public `fetchStatus`, `targetTimeline`, and `isUltraRapid`
were not labeled dead merely because production callers are absent. Framework
callbacks and executable entry points are also retained. These distinctions
avoid deleting supported library APIs or framework-dispatched code.

## Checks and evidence

- Initial working tree was clean. Repository contains 85 tracked files.
- Swift 6.4 is available on arm64 macOS, with Xcode selected.
- The package defines a library, two executables, and two test targets.
- Both dependencies are pinned and recorded in `Package.resolved`.
- The 2026-07-25 review is a historical record and remains unchanged.
- Baseline `swift test` passed: 166 tests across 31 suites, 162 library tests and
  4 app tests. It built all package targets. Charts emitted a non-failing
  `Custom UnitPoint values are not supported in AxisValueLabel` warning.
- Reproductions use synthetic inputs and temporary files outside the repository.
- Full pipeline probes confirmed CORE-01, CORE-02, and CORE-04. A zero basal
  profile became a rounded daily basal recommendation of 1.2 U despite an
  unchanged raw zero schedule.
- `swift build -c release` passed. CLI help and seven invalid-input probes
  behaved as expected. `bash -n scripts/dev.sh` passed.
- A controlled capped transport reproduced DATA-04 through the actual
  `TuningPipeline.fetchInputs` API, without network access or private data.

### Verification method

The core pipeline probes linked the actual built library and pinned model
objects. The DST and low-rate rounding probes also executed the production
source. Security probes compiled the actual client, DTO, cache, and credential
helper sources; the redirect and error cases used local servers or a refused
local connection. The app-state probes compiled the actual view model with a
controlled runner and in-memory persistence stand-ins, without touching the
real Keychain. Crash probes ran in separate processes so their traps did not
interrupt the audit. These probes were temporary and were not added as tests.

Representative observed outputs, using synthetic data only:

```text
Late profile change: settingsChanges=1 samples=264 ISF=100 pumpISF=40 CR=30 pumpCR=10
Zero basal: pumpDaily=0 recommendedRoundedDaily=1.2
CGM cadence 60/300/900 seconds: hour3Basal=1.2/1.117/1.036
Minimum evidence: 12 minutes of one-minute readings accepted as 12 samples
DST repeated 01:15: direct=1 expanded=2
Pre-change bolus: recordedSensitivityEffect=-1.076170 newProfileEffect=-2.152340
Carb lookback: fullCOB=1.547497 trimmedCOB=0
Capped fetch: dosesAvailable=1501 returned=1500; profilesAvailable=101 returned=100
Historical baseline after capped fetch: actualBasal=0.5 assignedBasal=1.0
Cross-origin redirect: apiSecretForwarded=true
Network error: genericDescriptionContainsToken=true
Timestamp cache encoding, legacy offset, and short hourly arrays: signal=5
```

### Security checks and existing safeguards

- The current-tree heuristic secret scan covered all 85 baseline tracked files.
  The only candidate was an existing synthetic test URL. Matched values were
  not printed. This was not a full Git-history or binary-artifact secret scan.
- Run IDs and cache day keys reject path traversal. Cache and run-history
  directories use `0700`; health-data files use `0600`. Existing permission and
  traversal tests pass. Ordinary remote HTTP is rejected; SEC-01 concerns the
  exception check.
- Credential writes check Keychain results. The production client issues GET
  requests. No production server-write or shell-execution path was found.
- Both dependencies are pinned. The checked public advisory endpoints returned
  no published advisories for
  [ArgumentParser](https://api.github.com/repos/apple/swift-argument-parser/security-advisories)
  or [LoopAlgorithm](https://api.github.com/repos/LoopKit/LoopAlgorithm/security-advisories).
  This is a narrow advisory check, not proof that either dependency is free of
  vulnerabilities.
- CI uses mutable `actions/checkout@v4` and no explicit token permissions.
  Pinning its revision and setting `permissions: contents: read` would reduce
  supply-chain exposure. These are hardening suggestions, not confirmed exploits.
- An explicit URLSession cache and cookie policy would clarify network-data
  retention. User caches were not inspected, so no separate cache-disclosure
  finding is claimed.
- Apple's [redirect delegate documentation](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:))
  describes the hook needed to reject or replace redirected requests for SEC-03.

## Coverage ledger

The baseline has 85 tracked files: 53 production Swift files, 17 test files,
5 fixture files, 8 root/build/script files, and 2 existing review-archive files.
The Swift files total 11,131 lines including tests and the package manifest.
Source locations in this report refer to the audited baseline.

| Area | Files | Review focus and related findings |
| --- | ---: | --- |
| Library Nightscout | 6 | Transport, credentials, DTOs, decoding, cache; SEC-01 to SEC-04, DATA-01, DATA-03, DATA-04 |
| Library persistence | 2 | Run identity, serialization, limits, deletion, permissions; DATA-02, APP-02 |
| Library model and support | 9 | Schedules, adapters, units, time zones; CORE-03, CORE-06, schedule duplication |
| Library ingest | 3 | Profile history, glucose filtering, dose/carbohydrate/override conversion; DATA-04, CORE-06 |
| Library replay | 2 | Model wiring, input retention, cadence, lookup math; CORE-03, CORE-05 to CORE-07 |
| Library tuning | 9 | Categorization, basal/ISF/CR math, schedule blocks, caps, chaining; CORE-01, CORE-04, CORE-05, ARC-02 |
| Library recommendations | 6 | Guardrails, final rounding, schedule conversion, text/JSON, persistence; CORE-02, DATA-02, ARC-02 |
| Library diagnostics | 2 | Recorded versus recommended replay, hourly/day summaries, charts' inputs; CORE-06, CORE-07 |
| Library pipeline and root | 2 | Fetch completeness, cache use, input validation, evidence boundary, version; DATA-01, DATA-04, CORE-05 |
| macOS app | 11 | State, credentials, history, results, tables, charts, units, failure reporting; SEC-02, SEC-04, APP-01, APP-02, ARC-01 |
| CLI | 1 | Authentication precedence, options, validation, cache and output paths; invalid-input probes pass |
| Library and app tests | 17 | Coverage, assertions, API contracts, gaps exposed by synthetic probes |
| Fixtures and fixture documentation | 5 | Three parity scenarios, scope, provenance, regeneration; DOC-01 |
| Root, build, and scripts | 8 | Package manifest and lock, CI, ignore rules, README, plan, license, development script |
| Existing review archive | 2 | Historical findings and verification claims reconciled with current source |

The previous fixes for profile segmentation, smoothing caps, and interval
normalization are present. CORE-04, CORE-06, CORE-02, and CORE-05 expose remaining
integration cases that those fixes and tests do not cover. The old report
already identified `ConnectionForm` as unused. It remains in the current tree.

`PLAN.md:188` also retains the old claim that no ISF blocks are invented and a
flat ISF remains a single value. Its later decision section and current README
describe the new six-hour suggestions correctly. Update that stale paragraph
as documentation maintenance; it is not counted as another runtime defect.

## Review log

- Established the baseline and split review across security, core algorithm,
  architecture, and application integration. Existing archive conventions place
  this report alongside the previous whole-application review.
- Recorded the first confirmed security, cache-identity, cap-enforcement, DST,
  and dead-code findings while validation continues.
- Baseline tests passed. Added cross-origin redirect and corrupt-history
  reproductions, and verified the late-profile-change problem through the
  public offline pipeline.
- Verified cadence, historical lookback, carb-tail retention, bounded fetches,
  and in-flight app settings. Public array traps also reproduced in isolated
  subprocesses linked against the actual built library.
- Reconciled 20 confirmed findings, grouped shared causes, and separated four
  architectural candidates and security hardening suggestions. Completed the
  report after baseline tests, release build, CLI probes, and evidence review.

## Limitations

- No live Nightscout account, private health data, or physical pump was used.
  Network completeness tests model a server honoring its requested record limit.
  No production-server penetration test or real-data accuracy study was performed.
- Runtime checks ran on arm64 macOS with Swift 6.4. The declared macOS 14 minimum,
  Intel hardware, and other OS/toolchain versions were not exercised separately.
- Existing chart render tests passed. The full native interface was source
  reviewed, not driven through every interaction. App-state reproductions use
  controlled dependencies as described above.
- Dependency source inspection focused on model semantics involved in the
  findings. Neither dependency received a complete independent source audit.
- Secret and advisory checks have the limits stated above. Repository clinical
  and numerical efficacy claims were not validated. The audit makes no claim
  about clinical effectiveness.
- No fixes were applied. The passing baseline suite does not resolve any finding
  in this report; each requires its own implementation and regression check.
