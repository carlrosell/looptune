# 0009. Remove URL user information from site addresses

- **Status:** Accepted
- **Date:** 2026-10-13
- **Deciders:** Project owner
- **Related:** [#5](https://github.com/carlrosell/looptune/issues/5) (SEC-02), [Repository audit](../docs/code-reviews/2026-10-12-repository-audit-review.md#sec-02-url-user-information-survives-sanitization), [ADR 0003](0003-canonical-site-origin.md), [ADR 0006](0006-same-origin-redirects.md), [#7](https://github.com/carlrosell/looptune/issues/7) (SEC-04), [#19](https://github.com/carlrosell/looptune/issues/19) (APP-01)

## Context

`NightscoutClient.normalizeBaseURL` and `CredentialStore.sanitizedURLString`
each removed the path, query, and fragment from an entered URL, but kept its
user and password. A synthetic
`https://audit-user:audit-password@example.com/path?token=audit-token#fragment`
kept both fields in the client's `baseURL`, in every request built from it,
and in the string the app writes to UserDefaults after a successful run. The
transport accepted request URLs with user information, including a
same-origin redirect target that added it. Preferences written by earlier
versions can already hold such a URL.

Nightscout authenticates with an access token in the query or an
`api-secret` header, which LoopTune sends from its own credential fields. It
does not use URL user information. Uploaders such as xDrip+ document a
`https://SECRET@site/api/v1/` address, so users may paste one.

ADR 0003 defines `SiteOrigin`, whose canonical URL never carries user
information, and suggested building stored URLs from it. ADR 0006 made
`TransportPolicy` the shared rule for which URLs a request may reach.

## Decision

URL user information is removed from entered site addresses and refused by
the transport. It is never used as a credential.

- `SiteOrigin.url(fromUserInput:)` reads an address as entered: it trims
  whitespace and treats an address without `://` as `https`. Both client
  initializers and the preferences sanitizer parse with it and require a
  `SiteOrigin`.
- The client's `baseURL` is the origin's canonical URL, which has no user
  information. The plain-HTTP loopback rule is still checked on the host as
  entered, because canonicalizing can turn a rejected spelling such as
  `[::0.0.0.1]` into `[::1]`.
- `CredentialStore.sanitizedURLString` removes the user, password, path,
  query, and fragment and lowercases the scheme and host. It keeps the
  entered host and port spelling, so the Keychain `accountKey` of the stored
  URL is the account its token is saved under. The store's URL setter applies
  it, so no other form reaches UserDefaults.
- When the app restores settings, a stored URL that differs from its
  sanitized form is replaced by that form, or removed if it has no origin.
  Removing user information does not change the account key, so the saved
  token is still found.
- `TransportPolicy.permits` refuses a URL with any user information,
  including an empty one. `URLSessionTransport` therefore throws
  `NightscoutError.invalidURL` before sending such a request and refuses such a
  redirect target with `disallowedRedirect`, even within the same origin.

Removal applies to every form `URLComponents` parses as user information: a
user only, a password only, an empty prefix (`https://@host`), and
percent-encoded values.

## Alternatives considered

- **Reject addresses with user information.** This fails closed, but the only
  available message is the generic invalid-URL text, which blames the scheme.
  SEC-04 owns that text. Stripping matches how pasted paths and `?token=`
  queries are already handled. The site still loads, and if it needs
  credentials Nightscout's refusal points the user to the token field.
- **Use the user information as the token or API secret.** This would add a
  credential source and persistence path outside the Keychain flow. The
  issue excludes it.
- **Strip only, without a transport check.** Requests built by injected code
  or redirect targets would bypass the normalizers. The transport check costs
  nothing for a well-formed client.
- **Store the origin's canonical URL.** `accountKey` distinguishes
  `example.com` from `example.com:443` and keeps other host spellings that the
  origin normalizes. A canonical stored URL would look up a different
  Keychain account from the one the token was saved under, and the app would
  lose a saved token. Deriving the account from `SiteOrigin` needs a
  migration of existing Keychain items, which is separate work.

## Consequences

The secret in a pasted URL never reaches a request, a redirect, or
preferences. A credential-bearing URL saved by an earlier version is cleaned
on the next launch without being written back. Stored URLs without user
information are unchanged, and Keychain accounts are unchanged.

The client's `baseURL` now uses the canonical spelling. An explicit default
port is dropped, and IPv6 literals and percent-encoded hosts are normalized.
Requests reach the same origin as before.

The error for a refused address is unchanged until SEC-04.

Verification: `URLUserInfoTests` covers the normalizer and both initializers
across user information forms, the requests a stub transport receives, the
transport policy and redirect check, and the real `URLSessionTransport`
against a loopback server. That transport test refuses a request URL with
user information and a same-origin redirect that adds it. On `main` at
`9448dfb`, five of its six tests fail. `CredentialStoreTests` uses isolated
UserDefaults suites to cover sanitizing, the setter, and restoration of a
credential-bearing, an invalid, and an already sanitized value. It also checks
that sanitizing keeps the entered URL's Keychain account.
