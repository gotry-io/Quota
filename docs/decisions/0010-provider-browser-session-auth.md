# ADR 0010: Provider browser-session authentication

## Status

Accepted

> Updated 2026-08-26: `browser_session` is declared for Cursor only, a consent popup gates the
> first cookie read, and a refused store is its own reported outcome.

## Context

Some providers expose account quota only through an authenticated browser session. Quota needs a
macOS acquisition path without moving credential validation, persistence, or provider networking
out of the Rust service. The released managed Account/Relay v2 protocol also has a closed provider
enum that cannot accept new local providers without a new protocol version.

## Decision

Declare browser-session acquisition and managed-account synchronization independently in the
[provider catalog](../../packages/provider/catalog.json). Only a provider with no other way to be
read declares one: Cursor has no CLI sign-in and no API key, and is the only such provider.
Codex, Claude Code, Grok, and Kimi Code each keep a grant their own program renews, so they
declare none and QuotaBar never opens a cookie store for them.

QuotaBar asks before it reads. A confirmation popup names the browser about to be read, the
permission macOS will ask for (Full Disk Access for Safari, the "Chrome Safe Storage" Keychain
item for a Chrome-family browser), the exact hosts and cookie names read, that the accepted
session is stored in the local service database until disconnected, and that none of it is
uploaded. Declining opens no store.

QuotaBar then uses the declared allowlist to read matching cookie records into bounded Swift
memory and sends one candidate at a time over private child stdin. Each allowlisted name on each
host is its own candidate; hosts and browser profiles are never combined. Rust revalidates the
catalog rules, verifies the provider account, performs provider networking, and stores the session
in the owner-only local SQLite state. Catalog `browser_session.exclusive` marks the session as
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
