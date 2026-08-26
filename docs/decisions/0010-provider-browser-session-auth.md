# ADR 0010: Provider browser-session authentication

## Status

Accepted

> Updated 2026-08-26: a consent popup gates the first cookie read, a refused store is its own
> reported outcome, and `browser_session` is declared for every provider with a web session — as
> the ladder's last rung.

## Context

Some providers expose account quota only through an authenticated browser session. Quota needs a
macOS acquisition path without moving credential validation, persistence, or provider networking
out of the Rust service. The released managed Account/Relay v2 protocol also has a closed provider
enum that cannot accept new local providers without a new protocol version.

## Decision

Declare browser-session acquisition and managed-account synchronization independently in the
[provider catalog](../../packages/provider/catalog.json). Every provider whose web app has a
signed-in session declares one — Cursor, Codex, Claude Code, Grok, Kimi Code — and it is always
the last rung: read only when that provider's own credential is absent or every rung that read it
answered `auth_required`, never ahead of a working one, and never after one this Mac was refused.

QuotaBar asks before it reads. A confirmation popup names the browser about to be read, the
permission macOS will ask for (Full Disk Access for Safari, the "Chrome Safe Storage" Keychain
item for a Chrome-family browser), the exact hosts and cookie names read, that the accepted
session is stored in the local service database until disconnected, and that none of it is
uploaded. Declining opens no store.

QuotaBar then uses the declared allowlist to read matching cookie records into bounded Swift
memory and sends one candidate at a time over private child stdin. A name that is a whole sign-in
is its own candidate; the two that are halves — numbered NextAuth chunks and Grok's `sso`/`sso-rw`
— share one header, and a cookie naming the account a session acts as rides along. Hosts and
profiles are never combined. Rust revalidates the catalog rules, verifies the provider account,
performs provider networking, and stores the session in owner-only local SQLite; where a
provider's official rung has a `global` identity the browser rung builds the same fingerprint, so
the ladder cannot rename a subscription. Catalog `browser_session.exclusive` marks the session as
lacking an official CLI or API-key sign-in command; Settings then omits that command row. Cursor is
exclusive. It still discovers a signed-in Cursor.app session from local desktop state, as defined
by [provider collection](../provider-collection.md).

A read macOS refuses is not an absent session. The importer answers `noSession`, `accessDenied`, or
`found`; a refusal names the browser and one of `full_disk_access`, `keychain_refused`, or
`store_unreadable`, ends the attempt, and travels the browser-session commit so the service records
it as the `browser_access_denied` source code on the Support page. The underlying error's text
names a store path and never leaves Swift.

The credential and redaction boundary is specified in [security](../security.md), and provider API
behavior remains in [provider collection](../provider-collection.md).

## Consequences

Browser/profile discovery can later move to Rust without changing authentication authority or
persistence. Browser cookies never enter Relay or managed-account payloads. Adding a provider to the
local catalog does not automatically make it network-compatible; managed synchronization requires
explicit `account_sync` catalog decision.
