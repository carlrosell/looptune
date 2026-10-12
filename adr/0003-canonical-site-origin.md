# 0003. Identify sites by canonical origin

- **Status:** Accepted
- **Date:** 2026-10-12
- **Deciders:** Project owner
- **Related:** [#8](https://github.com/carlrosell/looptune/issues/8) (DATA-01), [Repository audit](../docs/code-reviews/2026-10-12-repository-audit-review.md#data-01-cache-keys-mix-sites-hosted-on-different-ports), [#5](https://github.com/carlrosell/looptune/issues/5) (SEC-02), [#6](https://github.com/carlrosell/looptune/issues/6) (SEC-03), [#20](https://github.com/carlrosell/looptune/issues/20) (APP-02)

## Context

The pipeline keyed the day cache with `client.baseURL.host`. Two Nightscout
sites on one hostname, such as `http://localhost:1337` and
`http://localhost:8080`, read each other's cached glucose and treatments.
Profiles are always fetched live, so a run could combine one site's settings
with another site's records. A synthetic pipeline test reproduced this: the
second site made no data requests and received the first site's readings.

The client normalizer, the credential account key, the cache key, and saved-run
provenance each describe a site differently. The audit traced SEC-01, SEC-02,
DATA-01, and APP-02 partly to that duplication. Old cache directories record
only a sanitized hostname, so the scheme and port of their data cannot be
recovered.

## Decision

`LoopTuneKit` owns site identity through `SiteOrigin`, the tuple of scheme,
normalized host, and effective port:

- The scheme is `http` or `https`, lowercased. Other schemes have no origin.
- The host is percent-decoded and lowercased. Internationalized names use the
  punycode form returned by `URL`. IPv6 literals are stored unbracketed in
  compressed form; zone IDs are rejected. A trailing dot is kept, so
  `example.com.` and `example.com` are distinct.
- A host other than an IPv6 literal must be a name: dot-separated labels of
  1…63 characters from `a-z`, `0-9`, `-`, and `_`, not starting or ending
  with `-`, with at most 253 characters before an optional trailing dot. If
  the last label is numeric (decimal, or `0x` hex), the host must be a
  canonical dotted-quad IPv4 literal without a trailing dot. Decoded spaces,
  control characters, `/`, `@`, `#`, `?`, `%`, empty labels, and IPv4
  shorthand such as `127.1` leave a URL without an origin.
- An origin exists only if its canonical URL parses back to the same scheme,
  host, and port, so `url` and `description` are always available.
- The port is explicit or the scheme default (443 or 80) and must be in
  1…65535. `https://example.com` and `https://example.com:443` are equal.
- User information, path, query, and fragment are not part of the origin and
  never appear in its canonical URL or description.

`SiteOrigin(url:)` derives the origin. `url` and `description` give the
canonical base URL, omitting a default port. `NightscoutClient.origin` is set
when the client is created, and a URL without an origin is rejected as invalid.
The origin is an identity, not a transport policy: whether plain HTTP is
allowed remains the client's decision.

The day cache uses a versioned layout,
`DayCache/v2/<scheme>_<host>_<port>/<yyyy-MM-dd>.json`. The host keeps only
`a-z`, `0-9`, `.`, and `-` and percent-encodes other bytes, so each origin maps
to one readable directory name. The hostname-only layout is never read. Pruning
deletes its day files and any directory they leave empty. Those days are
refetched; no entry is assigned to an origin it cannot be proven to belong to.

## Alternatives considered

- **Add the port to the hostname key.** This fixes the reported collision but
  keeps `http` and `https` together and leaves each consumer to define default
  ports and host case again.
- **Migrate old entries to the selected site.** The old key cannot distinguish
  `localhost:1337` from `localhost:8080`, so any assignment could mix sites.
  The cost of discarding them is one refetch of at most 30 days.
- **Hash the origin for the directory name.** A digest is injective in
  practice, but the cache is meant to be inspectable on disk.
- **Store the origin in each cached file and check it on load.** The directory
  mapping is already one-to-one, so this adds a format field without
  preventing a further failure mode.

## Consequences

Each site reads only its own cache, and equivalent spellings of one site still
share entries. Existing users refetch cached days once after upgrading.
`DayCache.load` and `store` take a `SiteOrigin` instead of a host string; there
is no hostname-only cache API.

Later work should use `SiteOrigin` instead of another normalizer: SEC-03 can
compare redirect origins for equality, SEC-02 can build stored URLs from the
canonical URL, which carries no user information, and APP-02 can record and
display a run's origin. Those changes remain their own tasks. The client's
`baseURL` normalizer and the app's credential account key are unchanged here.

Verification: `SiteOriginTests` covers default ports, host case, IPv6
spellings, rejected URLs and hosts, canonical URLs, and the round trip from
each accepted origin through its canonical URL. Pipeline tests use a
deterministic transport and temporary cache to show port isolation and that a
seeded hostname-only entry is refetched and deleted.
