# 0005. Fetch complete Nightscout records or fail

- **Status:** Proposed
- **Date:** 2026-10-12
- **Deciders:** Project owner
- **Related:** [#11](https://github.com/carlrosell/looptune/issues/11) (DATA-04), [Repository audit](../docs/code-reviews/2026-10-12-repository-audit-review.md#data-04-fixed-fetch-limits-silently-truncate-records-and-profile-history), [ADR 0003](0003-canonical-site-origin.md), [#17](https://github.com/carlrosell/looptune/issues/17) (CORE-06), [#18](https://github.com/carlrosell/looptune/issues/18) (CORE-07)

## Context

`TuningPipeline.fetchInputs` asked for 100 profile documents and for 1,500
entries and 1,500 treatments per UTC day, and used whatever came back. Nightscout
returns the newest `count` matches without saying more exist. A synthetic
transport that honored `count` returned 1,500 of 1,501 doses without an error,
and 100 of 101 profiles. `ProfileHistory.activeProfile` then fell back to the
earliest returned profile and assigned basal 1.0 to an instant whose missing
older profile specified 0.5. A truncated day could also be cached and reused.

The client can rely only on what the v1 API already accepts: `find[date]` and
`find[created_at]` range filters with `$gte` and `$lte`, and `count`. The
profile endpoint accepts `count` alone and sorts by `startDate`, newest first.
There is no skip or cursor parameter that every supported server honors.

## Decision

A fetch either retrieves every record the analysis can read or throws. It never
returns, analyzes, or caches data it knows may be incomplete.

**Records.** Queries request 1,500 records. A response that holds 1,000 or
more may be truncated: either it fills the request, or a server or proxy capped
it below the request, as Nightscout API v3 and common proxies do at 1,000. The
range is split at its midpoint and both halves are queried again, newer half
first, until every queried range returns fewer than 1,000 records. The halves
share the inclusive midpoint, and records returned twice are dropped: treatments
by sync identifier, then `_id`, then the whole decoded document; entries by
every decoded field. Splitting relies only on the range
filter and `count`, not on which matches the server returns first. Split points
lie on the filter's grid (milliseconds for entries, whole seconds for
treatments). A full range narrower than two grid steps, or a day that needs more
than 64 queries for one collection, throws
`PipelineError.incompleteRecords(collection:start:end:)`. The 64-query budget
also stops a server that ignores the range filter. Because a split query yields
two more, 64 queries end in about 32 ranges below 1,000 records, roughly 30,000
records in an evenly spread day. A one-minute CGM day of about 1,440 entries
takes three queries.

**Profile history.** The required boundary is the earliest instant replay can
read: `analysisStart - ReplayEngine.inputLookback`, where `inputLookback` is the
largest of the replay lookbacks. Profiles are requested with `count` 100,
doubling to at most 3,200. A response with fewer documents than requested is
the site's whole history, with two exceptions. Nightscout returns 10 documents
when `count` is dropped, so a response of exactly 10 is accepted only after a
request with `count` 1 returns fewer than 10, which shows `count` is honored. A
response of 1,000 or more may be a server cap and is rejected. A full response
is accepted only if it contains a document that started at or before the
boundary and later than the oldest returned start date, because documents tied
with the oldest one may have been cut off. Otherwise the fetch throws
`PipelineError.incompleteProfileHistory(requiredFrom:)`.

The data window starts `max(1 day, ReplayEngine.inputLookback)` before the
analysis start. Fetching contains no replay duration of its own; the replay code
owns `inputLookback` and must keep it at least as long as anything replay reads.

**Cache.** A day is stored only after both collections were retrieved
completely, and `CachedDay` records this as `"complete": true`. The pipeline
reuses only days marked complete. Days stored by earlier versions decode as
incomplete and are refetched and replaced.

When the site's whole profile history starts after the boundary, there is no
older document to fetch. That case keeps the existing behavior: the earliest
profile is used for earlier instants.

## Alternatives considered

- **Cursor paging on the oldest returned timestamp.** Fewer queries for dense
  days, but it is only correct if the server returns the newest matches. A
  server that returned the oldest matches would make it skip records silently.
  Splitting stays correct either way.
- **Raise `count` to a larger fixed value.** This moves the cliff without
  detecting it.
- **Use unsupported skip or `find[startDate]` parameters.** Older or customized
  Nightscout servers may ignore them, and an ignored filter looks like success.
- **Reject runs whose profile history has no document before the boundary even
  when the history is complete.** That would reject every new site and every
  site with a single undated profile. The truncation this decision prevents is
  a fetching gap; settings that were never uploaded are outside its scope.
- **Bump the cache layout to `v3`.** It would also discard old days, but the
  completeness mark states the actual property and keeps the ADR 0003 layout.

## Consequences

Dense sites, such as one-minute CGM data or several uploaders, are analyzed with
all their records at the cost of extra queries for full days. A day that cannot
be retrieved completely, or a profile history that cannot be shown to reach the
replay lookback within 3,200 documents, stops the run with an explicit error.
Existing caches are refetched once after upgrading. If replay comes to read
further back, raising `ReplayEngine.inputLookback` extends both the data window
and the profile boundary.

The design assumes a server honors the `count` it is sent, caps responses at
1,000 or more, or drops `count` and returns 10. A server or proxy that caps
responses below 1,000, including one that honors `count` 1 but caps at 10, still
looks complete. A site whose whole profile history is exactly 10 documents, all
newer than the boundary, costs one extra profile request. Dense days split once
responses reach 1,000 records rather than 1,500.

Verification: `CompleteFetchTests` uses a synthetic transport that can honor,
cap, or drop `count`. Saturated treatments and entries are fully retrieved. A
day of 1,000 records is split although it is below the request, and records on
the split midpoint are not doubled. A server capped at 1,000 returns all 1,440
entries of a one-minute CGM day and 1,001 doses in three queries each.
Unsplittable or non-progressing ranges are rejected within the query budget.
The 101-profile case fetches the 0.5 U/h baseline, a covered history needs one
request, tied oldest documents are extended, and an unbounded history is
rejected. Ten profiles from a server that drops `count` are rejected, ten from a
server that honors it are accepted, and a profile response at a 1,000-document
cap is rejected. Incomplete days are not cached, complete saturated days are
reused, and unmarked days are refetched.
