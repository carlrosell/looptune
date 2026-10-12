# 0006. Follow redirects only within the request's origin

- **Status:** Proposed
- **Date:** 2026-10-12
- **Deciders:** Project owner
- **Related:** [#6](https://github.com/carlrosell/looptune/issues/6) (SEC-03), [Repository audit](../docs/code-reviews/2026-10-12-repository-audit-review.md#sec-03-cross-origin-redirects-forward-the-api-secret), [ADR 0003](0003-canonical-site-origin.md), [#4](https://github.com/carlrosell/looptune/issues/4) (SEC-01), [#5](https://github.com/carlrosell/looptune/issues/5) (SEC-02), [#7](https://github.com/carlrosell/looptune/issues/7) (SEC-04)

## Context

`URLSessionTransport` used `URLSession.shared` without a redirect delegate,
so `URLSession` followed every redirect and copied the request's headers to
the new target. The client checks the transport policy (HTTPS, or plain HTTP
to a loopback host) only on the base URL it was created with. A synthetic
reproduction through the real transport on `main` at `0ea1742`: a server on
`127.0.0.1` answered 302 with `Location: http://localhost:<other-port>/…`, the
second server received the `api-secret` header, and `fetchStatus()`
succeeded. The header is the SHA-1 the site accepts as authentication, so it
is a usable credential. A token travels in the query, so it is forwarded when
the redirect target repeats it.

ADR 0003 defines `SiteOrigin` and leaves transport policy to the client.

## Decision

Every request the default transport sends, including each redirect hop, must
pass the transport policy, and a redirect is followed only when its target has
exactly the origin of the original request:

- Before sending, `URLSessionTransport` requires the request URL to have a
  `SiteOrigin` and to use HTTPS, or plain HTTP to a host accepted by the
  SEC-01 loopback rule. Otherwise it throws `NightscoutError.invalidURL`
  without contacting anything.
- A per-task `URLSessionTaskDelegate` checks each redirect against the origin
  of the original request, not the previous hop, so a chain cannot leave the
  site through a same-origin first hop. The target must pass the transport
  policy and `SiteOrigin(url:)` must equal that origin. A target without an
  origin is a mismatch. A target whose host is percent-encoded is refused,
  because the decoded host behind its origin need not be the host a
  connection would use.
- A refused redirect is never requested. The transport throws
  `NightscoutError.disallowedRedirect`, which carries no URL.
- The rule applies to every request, with or without credentials. The
  transport cannot reliably tell which requests are authenticated (headers,
  query items, and URL user information all carry credentials), and data
  fetched from another origin would be cached and reported under the
  configured site's identity.
- Same-origin redirects, such as a moved path or a different spelling of the
  same host and port, are followed with the original headers.
- A same-host upgrade from `http` to `https` is refused. It changes the origin
  and the effective port, so following it would attribute another origin's
  data to the configured site. Plain HTTP is only accepted for loopback hosts,
  so the credentials of the first request have already been sent unencrypted
  on the local machine and an upgrade would not protect them. Users of a site
  that upgrades enter its HTTPS address.

`TransportPolicy` holds the loopback rule from SEC-01 and the redirect check,
so the base-URL normalizer and the transport share one definition. The
`NightscoutTransport` protocol is unchanged; injected transports remain
responsible for their own network behavior. Certificate validation stays
with the session's default handling.

## Alternatives considered

- **Reject cross-origin redirects only for authenticated requests.** Public
  sites need no credentials, but their redirected data would still be
  attributed to the configured origin, and the transport would have to
  detect every way a request carries credentials.
- **Strip credentials and follow cross-origin redirects.** This prevents the
  disclosure but still reads another site's records as the configured site's.
- **Allow same-host `http` to `https` upgrades.** The target is a different
  origin and port under ADR 0003, and loopback HTTP gains nothing from it.
- **Refuse all redirects.** Same-origin path redirects from a reverse proxy
  keep both the credentials and the data on the configured site, so refusing
  them would break working setups without a security benefit.
- **Cancel the task from the delegate.** This surfaces as a generic
  cancellation error. Refusing the redirect returns the redirect response,
  which the transport converts into a specific error.

## Consequences

Credentials and requests stay on the configured origin, and the transport
policy is enforced on every hop the default transport makes. A site that
redirects to another host, port, or scheme now fails with a controlled error
instead of loading; the user must enter the final address. The app still
formats this error through its generic fallback until SEC-04 adds controlled
presentation.

Verification: `RedirectPolicyTests` uses the real `URLSessionTransport`.
Plain-HTTP cases use local servers on `127.0.0.1` and cover a cross-host
redirect with an API secret, a cross-port redirect repeating a token, a
same-origin redirect for both credentials, a chain whose second hop leaves the
origin, and the `http` to `https` upgrade. HTTPS cases run through a real
`URLSession` whose requests are answered in-process and cover a downgrade to
`http`, a redirect to a remote `http` host, a redirect to another HTTPS host,
and an equivalent spelling of the same origin. With the redirect check
disabled, seven of these tests fail.
