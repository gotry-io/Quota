# ADR 0006: Managed account, device, and Usage boundary

- Status: Accepted
- Date: 2026-08-10
- Supersedes: [ADR 0002](./0002-relay-device-code-pairing.md), [ADR 0004](./0004-anonymous-relay-owners.md), and [ADR 0005](./0005-url-only-relay-enrollment.md)

## Context

Quota needs one identity and data model for QuotaCLI, QuotaBar, and the website. Anonymous Relay
owners, arbitrary Relay URLs, and device-to-owner pairing made identity, deletion, and cross-device
Usage ambiguous. Those interfaces had not shipped as a production compatibility boundary.

Raw agent logs and provider credentials must remain local. The managed service needs only normalized
quota observations, sparse hourly Usage facts, coverage metadata, and the control state required for
safe retries and deletion.

## Decision

Quota supports one managed service at `https://quota.gotry.io` and GitHub is its only account identity
provider. Better Auth is the browser identity/session boundary and owns provider OAuth state, PKCE,
cookies, expiry, and standard auth-route origin protection. Quota keeps only its product-specific
Device lifecycle and QuotaCLI token families. An Account directly owns Devices. QuotaCLI is the sole
native OAuth public client and the sole writer of installation identity, account/device sessions,
upload sequences, Usage cache, and Usage outbox. QuotaBar invokes its signed bundled QuotaCLI with
fixed arguments and renders typed output; it does not read credentials or QuotaCLI state files.

Browser login uses Authorization Code with PKCE and headless login uses the OAuth Device
Authorization Grant. Successful native login issues separate account-read and current-device-write
token families. Refresh tokens rotate with compare-and-swap semantics. Better Auth owns browser
Account deletion; its deletion hook removes the Quota domain Account and cascading business data.
Product-specific Device authorization and deletion additionally require recent authentication and
an exact same-origin request.

The installation ID is random user-level state. Relay stores only an account-scoped HMAC of it, so
the same installation restores the same Device within one Account without becoming a cross-account
identifier. Snapshot and Usage upload sequences are independent and server-authoritative.

QuotaCLI converts supported local Codex and Claude Code records into privacy-preserving hourly facts.
Uploads contain no prompt, completion, path, session ID, conversation ID, raw event, or provider
credential. Only a complete UTC-hour scan may replace a remote range; partial scans remain local.
Each immutable outbox submission has a stable ID, generation, and sequence, so retry and
crash-after-commit are idempotent. Pricing uses an effective-dated managed catalog and preserves
unknown or incomplete prices as explicitly unpriced rather than zero.

Logout first disables local upload and revokes sessions, but retains the remote Device and data.
Delete Device is a distinct authenticated Web action: it revokes sessions, advances the generation,
sets a precise deletion watermark, deletes business rows, and retains only a hidden tombstone. Old
tokens and outbox entries cannot restore deleted data. A new generation may rebuild the watermark's
UTC hour only from raw events at or after the precise watermark.

QuotaRelay runs only as a Cloudflare Worker backed by D1. The product has no self-hosted runtime,
SQLite adapter, Relay discovery document, arbitrary Relay URL, anonymous owner, or protocol v1 path.

## Consequences

- Account and Device lifecycle is consistent across CLI, QuotaBar, and Web.
- Local collection and cached display continue while signed out or offline; remote sync does not.
- The service can aggregate quota and Usage without receiving the underlying work or provider
  credentials.
- D1 migrations and the v2 protocol are intentional destructive cutovers for unreleased data and
  interfaces.
- Self-hosting requires a future decision. Additional identity providers can use Better Auth's
  provider boundary without creating a second session system, but still require an explicit product
  and privacy decision.
