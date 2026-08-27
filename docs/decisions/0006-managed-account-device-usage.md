# ADR 0006: Managed account, device, and Usage boundary

- Status: Accepted
- Date: 2026-08-10
- Supersedes: [ADR 0002](./0002-relay-device-code-pairing.md),
  [ADR 0004](./0004-anonymous-relay-owners.md), [ADR 0005](./0005-url-only-relay-enrollment.md)
- Updated 2026-08-26 by [ADR 0024](./0024-hour-versioned-usage-and-daily-rollups.md),
  [ADR 0025](./0025-one-session-system.md), and [ADR 0027](./0027-one-token-per-client.md), which
  left one session per client and no CLI or device grant

## Decision

Quota supports one managed service at `https://quota.gotry.io`, running only as a Cloudflare Worker
backed by D1, and GitHub is its only account identity provider. There is no self-hosted runtime,
SQLite adapter, Relay discovery document, arbitrary Relay URL, or anonymous owner. Relay owns the
browser OAuth round trip and the session it opens ([ADR 0025](./0025-one-session-system.md)).

**An Account directly owns Devices.** A Device's `display_name` is the host computer name collected
at login and reconciled by device sync — not the product name — so a session can repair an earlier
fallback and follow a host rename without a logout. The installation id is random user-level state
and Relay stores only an account-scoped HMAC of it, so the same installation restores the same Device
inside one Account without becoming a cross-account identifier.

**One writer.** QuotaBar's bundled Rust service is the sole collection OAuth public client and the
only writer of installation identity, sessions, Usage state, and the Usage outbox. Login is
Authorization Code with PKCE over a loopback callback, and issues one session that reads the Account
and writes this Device ([ADR 0027](./0027-one-token-per-client.md)); its refresh token rotates with
compare-and-swap semantics. The registered `quota-ios` public client is a read-only viewer
([ADR 0013](./0013-readonly-ios-account-client.md)), and Swift renders typed IPC state without
reading credentials or service files.

**Raw work stays local.** The service converts supported Codex, Claude Code, Grok, OpenCode, Pi, and
Cursor records into privacy-preserving hourly facts. An upload carries no prompt, completion, path,
session id, conversation id, raw event, or provider credential, and preserves opaque model ids.
Pricing uses an effective-dated managed catalog and keeps an unknown price unpriced, never zero.

**A durable per-installation Usage upload preference** belongs to the same service. Disabling it keeps
local collection and display, stops staging and draining the outbox, and shows Usage from This Mac
only; pending work resumes when re-enabled, and nothing is deleted remotely.

**Three lifecycle verbs, deliberately distinct.** Logout disables local upload and revokes sessions
while retaining the remote Device and its data. Delete Device revokes sessions, advances the
generation, sets a precise deletion watermark, deletes business rows, and retains only a hidden
tombstone, so an old token or outbox entry cannot restore deleted data. Delete Account is one Relay
D1 batch over the rows Relay keeps ([ADR 0025](./0025-one-session-system.md)). Both deletions
require recent authentication and an exact same-origin request, which only a browser can make.

OAuth and Device control keep their v2 contracts; quota, Usage, and Account summary follow the single
managed data contract, v6 today. The upload sequences, coverage metadata, and per-device health
snapshot this decision originally described are gone: an hour carries the version of the scan behind
it ([ADR 0024](./0024-hour-versioned-usage-and-daily-rollups.md)) and a Device reports only when it
last spoke ([ADR 0022](./0022-minimal-diagnostics.md)).

## Consequences

Account and Device lifecycle reads the same on QuotaBar and on the Web. Local collection and cached
display continue while signed out, offline, or with upload disabled; remote sync does not, and remote
Usage history is never implicitly deleted. The managed service aggregates quota and Usage without
receiving the work or the credentials that produced it. Self-hosting and a second identity provider
each remain a future product and privacy decision.
