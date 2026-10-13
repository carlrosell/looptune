# 0010. Show errors only through controlled messages

- **Status:** Proposed
- **Date:** 2026-10-13
- **Deciders:** Project owner
- **Related:** [#7](https://github.com/carlrosell/looptune/issues/7) (SEC-04), [Repository audit](../docs/code-reviews/2026-10-12-repository-audit-review.md#sec-04-network-error-messages-expose-query-tokens), [ADR 0006](0006-same-origin-redirects.md), [ADR 0009](0009-url-user-information.md)

## Context

`NightscoutClient` sends an access token as the `token` query parameter. When
a request fails, Foundation records the request URL, including that query,
in the error's `NSErrorFailingURLKey` and `NSErrorFailingURLStringKey`, and
sometimes again in a nested `NSUnderlyingErrorKey` error. Two places turned
such an error into displayed text:

- `TuningViewModel.describe` fell back to `"\(error)"`, and the sidebar and
  detail pane showed the result.
- The CLI let ArgumentParser print thrown errors. For an error that is not a
  `LocalizedError`, it prints `String(describing:)`.

On `main` at `b100df2`, a client with a synthetic token pointed at
`http://127.0.0.1:1` failed with `NSURLErrorCannotConnectToHost`. Both the
app's message and the stderr of `looptune fetch` and `looptune tune` contained
the token. ADR 0006 left `disallowedRedirect` to the same generic fallback,
and ADR 0009 left the invalid-URL text to this decision.

The library cannot make an arbitrary error's text safe. Localized
descriptions, debug descriptions, and user info are written by Foundation,
the system, or other code, and can quote the URL, the response, or the
request.

## Decision

Every error the app or CLI shows goes through `ErrorMessage.describe(_:)` in
LoopTuneKit. `TuningViewModel.describe` calls it, and the CLI rethrows any
failure from creating the client or running the pipeline as a
`LocalizedError` carrying that message.

A message is built only from the error's type, its case, and typed fields:
counts, HTTP status codes, dates, error codes, and the collection or field
names the library itself supplies. It never contains an error's localized
description, `String(describing:)` rendering, user info, or any URL.

- `NightscoutError` and `TuningPipeline.PipelineError` cases have their own
  messages, which keep the existing distinctions: authorization rejected, an
  invalid site address, a refused redirect, an HTTP status, malformed
  records, incomplete records or profile history, and insufficient data.
- `NightscoutError.decoding` carries the decoder's description, which can
  quote the response. Its message does not include it.
- `NightscoutError.partialDecoding` shows its `path` reduced to the
  percent-encoded path of a URL, so a scheme, host, user information, query,
  or fragment in the value is dropped. The client passes fixed API paths, and
  the token is never part of them.
- Network failures are classified by `NSError` domain and code, searching the
  error and then each error under `NSUnderlyingErrorKey`, to a depth of
  eight. The outermost specific code decides; a generic one such as
  `NSURLErrorUnknown` defers to the errors beneath it. `NSURLErrorDomain` and
  CFNetwork codes, POSIX connection and timeout codes, and Secure Transport
  statuses map to offline, cannot connect, host not found, secure connection
  failed, timed out, too many redirects, unreadable response, not authorized,
  invalid URL, and cancelled. Other URL loading codes show the numeric code.
- Any other error is "An unexpected error occurred" with a label: the domain
  and code for a system domain, the code alone for another `NSError` domain,
  and otherwise the Swift type name.

The library's `LocalizedError` descriptions are unchanged; they remain for
other callers and are not used for display.

## Alternatives considered

- **Redact the URL text in the error's description.** This keeps the full
  Foundation text, but the description is free-form and can repeat the URL in
  a form a redactor misses, such as percent-encoded or nested in another
  error's description. Classification by code gives the same distinctions
  without reading the text.
- **Show the failing host with the message.** The host is not a credential
  once ADR 0009 removed user information, but the user entered it and can
  already see it. Showing it would mean reading a URL back out of the error's
  user info, which is the field this decision stops trusting.
- **Wrap transport failures in a `NightscoutError` case.** This would protect
  every library caller, but changes the error contract programmatic callers
  receive and still needs a presentation rule for the other error types.
- **Move tokens from the query to a header.** This removes the token from
  failing URLs, but it changes how LoopTune authenticates to Nightscout and is
  separate work. Other error text would still need a presentation rule.

## Consequences

The app and CLI show the same message for an error, and no displayed message
contains a token, API secret, or other value an error carries. Diagnostics
lose the Foundation description; the classification and the numeric code
remain. A new error type is shown as unexpected until it gets a message.
The invalid-URL message now states the HTTPS rule.

Verification: `ErrorMessageTests` builds Foundation-shaped errors whose
failing URL, URL string, localized description, and nested errors carry a
synthetic token and URL user information. It covers connection, offline,
DNS, TLS, timeout, redirect, and unreadable-response codes as `NSError` and
`URLError`, nested underlying errors including POSIX and Secure Transport
causes, `disallowedRedirect`, `partialDecoding` with a hostile path,
`decoding`, and errors whose descriptions and domain carry the token.
`ErrorDescriptionTests` uses the real client against `http://127.0.0.1:1`:
the raw error contains the token, while `TuningViewModel.describe` and the
model's failed phase show the controlled connection message. On `main` at
`b100df2` that test fails.
