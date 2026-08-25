# ADR 0006: Managed account, device, and Usage boundary

- Status: Accepted
- Date: 2026-08-10
- Supersedes: [ADR 0002](./0002-relay-device-code-pairing.md), [ADR 0004](./0004-anonymous-relay-owners.md), and [ADR 0005](./0005-url-only-relay-enrollment.md)

## Context

Quota needs one identity and data model for QuotaBar's local service, native UI, and the website. Anonymous Relay
owners, arbitrary Relay URLs, and device-to-owner pairing made identity, deletion, and cross-device
Usage ambiguous. Those interfaces had not shipped as a production compatibility boundary.

Raw agent logs and provider credentials must remain local. The managed service needs only normalized
quota observations, sparse hourly Usage facts, coverage metadata, and the control state required for
safe retries and deletion.

## Decision

Quota supports one managed service at `https://quota.gotry.io` and GitHub is its only account identity
provider. Better Auth is the browser identity/session boundary and owns provider OAuth state, PKCE,
cookies, expiry, and standard auth-route origin protection.

> Updated 2026-08-26: Relay owns that boundary itself. Better Auth and its tables are gone; a
> hand-written GitHub OAuth flow writes one `account_sessions` row with `client_kind = 'web'`.
> See [ADR 0025](0025-one-session-system.md).

Quota keeps only its product-specific
Device lifecycle and native token families. An Account directly owns Devices. Each Device
`display_name` is the host computer name collected at login and reconciled by authenticated device
sync, not the QuotaBar or QuotaCLI product name. This lets a shipped session repair an earlier
product-name fallback and follow a later host rename without requiring logout. QuotaBar's bundled
Rust service is the sole collection OAuth public client and writer of
installation identity,
account/device sessions, upload sequences, Usage state, and Usage outbox. The registered
`quota-ios` public client is a read-only Account viewer as defined by
[ADR 0013](0013-readonly-ios-account-client.md). Swift renders typed IPC
state; it does not read credentials or service files.

The same service owns a durable per-installation Usage upload preference. Disabling it preserves
local collection and display, stops staging and draining the Usage outbox, and makes QuotaBar present
Usage from This Mac only. Pending work resumes after re-enabling. It is not a remote deletion action;
already uploaded data remains until the user invokes the existing Device or Account deletion flow.

Browser login uses Authorization Code with PKCE and headless login uses the OAuth Device
Authorization Grant. Successful collection-client login issues separate account-read and
current-device-write token families. Refresh tokens rotate with compare-and-swap semantics. Better Auth owns browser
Account deletion; its deletion hook removes the Quota domain Account and cascading business data.
Product-specific Device authorization and deletion additionally require recent authentication and
an exact same-origin request.

> Updated 2026-08-26: Account deletion is one Relay D1 batch over the rows Relay keeps, with no
> hook on another system. See [ADR 0025](0025-one-session-system.md).

The installation ID is random user-level state. Relay stores only an account-scoped HMAC of it, so
the same installation restores the same Device within one Account without becoming a cross-account
identifier. Snapshot and Usage upload sequences are independent and server-authoritative.

An authenticated collection Device may also replace only its own bounded Device Health snapshot.
The device token and generation determine the row; a request cannot select another Device. Relay
uses server receipt time for freshness, retains only the latest monotonic report, and deletes it with
the Device or Account. Account readers may display that snapshot but cannot write one. The data
minimization, freshness, and support-report rules are defined by
[ADR 0015](0015-diagnostic-attempts-and-device-health.md).

The local service converts supported Codex, Claude Code, Grok, OpenCode, Pi, and Cursor records into
privacy-preserving hourly facts. Uploads contain no prompt, completion, path, session ID,
conversation ID, raw event, or provider credential. Only a complete UTC-hour scan may replace a
remote range; partial scans remain local.
Each immutable outbox submission has a stable ID, generation, and sequence, so retry and
crash-after-commit are idempotent. Pricing uses an effective-dated managed catalog and preserves
unknown or incomplete prices as explicitly unpriced rather than zero.

QuotaCLI 0.0.5 shipped bounded protocol-v2 Usage behavior. The native-cutover compatibility window
completed with 0.0.6 and 0.0.7, and 0.0.8 removed its one-time import and version-specific Relay
behavior as defined in [ADR 0007](0007-rust-native-local-service.md). Current clients preserve
opaque model identifiers and request all agents and retained history with `usage_agents=all`. The
shared `providers.json`/`ProviderConfigLock` path and OAuth `client_id=quotacli` remain current
interfaces rather than compatibility behavior.

OAuth and Device control retain their released v2 contracts. Quota, Usage, and Account summary use
managed-data v3 from QuotaBar 0.0.12. The parallel v2 data routes were retired by
[ADR 0018](0018-single-managed-data-contract.md).
The version boundary is defined by [ADR 0012](0012-managed-data-v3.md).

Logout first disables local upload and revokes sessions, but retains the remote Device and data.
Delete Device is a distinct authenticated Web action: it revokes sessions, advances the generation,
sets a precise deletion watermark, deletes business rows, and retains only a hidden tombstone. Old
tokens and outbox entries cannot restore deleted data. A new generation may rebuild the watermark's
UTC hour only from raw events at or after the precise watermark.

QuotaRelay runs only as a Cloudflare Worker backed by D1. The product has no self-hosted runtime,
SQLite adapter, Relay discovery document, arbitrary Relay URL, anonymous owner, or protocol v1 path.

## Consequences

- Account and Device lifecycle is consistent across native QuotaBar and Web surfaces.
- Local collection and cached display continue while signed out or offline; remote sync does not.
- Local collection and display also continue while Usage upload is disabled; quota/account sync stays
  independent and remote Usage history is not implicitly deleted.
- Account surfaces can distinguish recent Device Health from an inactive Device without treating
  sleep, shutdown, or a closed app as a collection failure.
- The service can aggregate quota and Usage without receiving the underlying work or provider
  credentials.
- Earlier D1 and protocol cutovers applied only to unreleased data and interfaces. The bounded
  native-cutover exception ended after its documented two-release window.
- Self-hosting requires a future decision. An additional identity provider is another start and
  callback route resolving to the same `accounts` row, but still requires an explicit product and
  privacy decision.
