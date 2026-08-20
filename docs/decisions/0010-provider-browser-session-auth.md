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
the session as the only local auth path; Settings then omits the official CLI command. Cursor is
exclusive. Codex, Claude, Grok, and Kimi use the same acquisition path when OAuth or the Code API is
missing or rejected. Cursor synchronizes from managed-data v3 while released v2 routes retain their
closed provider enum, as defined by [ADR 0012](0012-managed-data-v3.md).

The credential and redaction boundary is specified in [security](../security.md), and provider API
behavior remains in [provider collection](../provider-collection.md).

## Consequences

Browser/profile discovery can later move to Rust without changing authentication authority or
persistence. Browser cookies never enter Relay or managed-account payloads. Adding a provider to the
local catalog does not automatically make it network-compatible; managed synchronization requires
explicit `account_sync` and `account_sync_protocol` catalog decisions.
