# ADR 0010: Provider browser-session authentication

- Status: Accepted
- Date: 2026-08-13

> Updated 2026-08-29: Browser Sign-in is a per-provider preference. QuotaBar scans every allowed
> browser and keeps every validated session. Official credentials still skip the browser rung.
>
> Updated 2026-08-30: enabling Browser Sign-in preflights Full Disk Access and Chrome-family
> Keychain grants, opens an independent window for what's missing, and never prompts during a
> background refresh.

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

QuotaBar asks before it reads. **Browser Sign-in** is the control: turning it on shows one short
confirmation that names the cookie names and hosts from the catalog, that accepted sessions stay
in the local service database until the scan is turned off, and that none of it is uploaded. The
macOS permission each browser needs is stated per installed browser in the Browser Access window,
not in the confirmation. Declining leaves the preference off and opens no store. There is no Sign In, Disconnect, browser picker, or account picker.

When the preference is on and this Mac's official credential is missing or answered
`auth_required`, QuotaBar reads every allowed browser that is installed, validates every
candidate, and stores every session that proves an account. A store macOS refuses is recorded
and the scan continues. When an official credential still answers, the browser jars are not
read. Turning the preference off deletes the stored sessions for that provider.

Consent stores the preference immediately, then preflights installed browsers so a later
refresh cannot fail a grant the user was never asked for. What is still missing is listed in the floating
Browser Access window — one row per installed browser with its icon, its gatekeeper, and one
action; Firefox is read directly and shows as ready. The scan continues with every store already
granted and does not wait for the others. Safari's action opens System Settings › Full Disk
Access, where the refused probe has already listed QuotaBar unchecked, so the copy leads with the
switch; the window also holds a QuotaBar icon that is a plain file drag of QuotaBar.app for that
list, activating System Settings before the drag, and after either the pane was opened or a drop
landed there it offers a relaunch, because macOS applies that grant to
a process on its next launch and this process cannot tell whether the person has added it yet.
A Chrome-family action is one Keychain read with UI allowed — the system prompt, where the
person should choose Always Allow — never a Settings pane. Background reads never show that
prompt: the silent probe goes through `SecKeychainSetUserInteractionAllowed(false)` (the only
switch that covers legacy login-keychain items), and scheduled scans skip Safari without Full
Disk Access and any Chromium jar whose ACL is not already allowed, recording each as a refusal.
The window closes itself when nothing is outstanding; dismissing it leaves the preference on,
and the Agent page keeps one summary row that reopens it.

A name that is a whole sign-in is its own candidate; the two that are halves — numbered NextAuth
chunks and Grok's `sso`/`sso-rw` — share one header, and a cookie naming the account a session
acts as rides along. Hosts and profiles are never combined. Rust revalidates the catalog rules,
verifies the provider account, and stores each session in owner-only local SQLite keyed by
provider and account fingerprint. Where a provider's official rung has a `global` identity the
browser rung builds the same fingerprint, so the ladder cannot rename a subscription. Catalog
`browser_session.exclusive` marks the session as lacking an official CLI or API-key sign-in
command; Settings then omits that command row. Cursor is exclusive. It still discovers a
signed-in Cursor.app session from local desktop state, as defined by
[provider collection](../provider-collection.md). The Browser Sign-in control is the same for
every catalog `browser_session` provider.

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
