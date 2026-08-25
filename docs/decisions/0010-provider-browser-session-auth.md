# ADR 0010: Provider browser-session authentication

## Status

Accepted

## Context

Some providers expose account quota only through an authenticated browser session. Quota needs a
macOS acquisition path without moving credential validation, persistence, or provider networking
out of the Rust service. The released managed Account/Relay v2 protocol also has a closed provider
enum that cannot accept new local providers without a new protocol version.

## Decision

Declare browser-session acquisition and managed-account synchronization independently in the
[provider catalog](../../packages/provider/catalog.json). QuotaBar uses the declared allowlist to
read only matching cookie records into bounded Swift memory and sends one candidate at a time over
private child stdin. Complementary same-host cookies (Grok `sso`/`sso-rw`, numbered ChatGPT session
chunks, plus optional `_account` or `lastActiveOrg`) share one header; unrelated allowlisted names
such as Cursor's `wos-session` and `WorkosCursorSessionToken` stay separate candidates. Hosts and
browser profiles are never combined. Rust revalidates the catalog rules, verifies the provider
account, performs provider networking, and stores the session in the owner-only local SQLite state. Catalog `browser_session.exclusive` marks
the session as lacking an official CLI or API-key sign-in command; Settings then omits that command
row. Cursor is exclusive. It still discovers a signed-in Cursor.app session from local desktop
state, as defined by [provider collection](../provider-collection.md). Codex, Claude, Grok, and
Kimi use the same browser acquisition path when OAuth or the Code API is missing or rejected.
Cursor synchronizes from managed-data v3, which [ADR 0018](0018-single-managed-data-contract.md)
made the only data contract; the retired v2 routes had kept their closed provider
enum, as defined by [ADR 0012](0012-managed-data-v3.md).

The credential and redaction boundary is specified in [security](../security.md), and provider API
behavior remains in [provider collection](../provider-collection.md).

## Consequences

Browser/profile discovery can later move to Rust without changing authentication authority or
persistence. Browser cookies never enter Relay or managed-account payloads. Adding a provider to the
local catalog does not automatically make it network-compatible; managed synchronization requires
explicit `account_sync` catalog decision.
