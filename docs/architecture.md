# Architecture

This document defines Quota's system boundaries and data paths. Product status and commands live in
the root [`README.md`](../README.md); credential and retained-data rules live in
[`security.md`](security.md).

## Product boundaries

Quota has four runtime products:

- QuotaCLI owns provider collection, random installation identity, account/device sessions, upload
  sequences, local Usage cache/outbox, pricing cache, and all managed-service HTTP calls.
- QuotaBar owns macOS presentation and scheduling. It invokes only its signed bundled QuotaCLI with
  fixed arguments and consumes bounded typed output.
- QuotaRelay owns GitHub-backed Accounts, Devices, scoped native sessions, normalized quota/Usage
  storage, deletion controls, and account queries. Better Auth owns its Web identity/session boundary.
  Relay runs only as a Cloudflare Worker backed by D1.
- Quota Web owns the public site and browser account UI. It shares `quota.gotry.io` with the Worker
  but remains a separate Vite application and source boundary.

GitHub is the only account identity provider. The service origin is fixed at
`https://quota.gotry.io`. The accepted boundary has no anonymous owner, pairing group, arbitrary
Relay URL, discovery document, self-hosted process, SQLite adapter, or protocol v1 route. The durable
decision is [ADR 0006](decisions/0006-managed-account-device-usage.md).

## Data paths

### Local collection

```text
provider sessions + agent logs
            │ local reads only
            ▼
        QuotaCLI ───────── typed local report ─────────► terminal
            │                                           QuotaBar
            └── owner-only cache/outbox
```

QuotaCLI uses `@gotry-io/quota-provider` to collect quota and to normalize supported Codex and Claude
Code log records. Provider credentials remain inside the collector boundary. Raw log records are not
written to the outbox. QuotaBar may retain one last safe normalized result for immediate display,
then replaces it after a successful helper invocation.

### Managed account and sync

```text
GitHub ── Better Auth web OAuth ──► QuotaRelay ──► browser account session
                                          │
browser PKCE / device authorization grant │ account + device token families
                                          ▼
QuotaCLI ── quota snapshots + hourly facts ──► D1
    ▲                                          │
    └──────── account summary / catalog ───────┘
                         │
                         ├──► QuotaBar
                         └──► Quota Web
```

QuotaCLI is the only native OAuth public client. Loopback browser login uses Authorization Code with
PKCE; headless login uses the OAuth Device Authorization Grant and a browser approval page. The
service returns separate account-read and current-device-write sessions. Access and refresh expiry
are explicit; refresh rotates atomically.

The random user-level installation ID is HMACed with an account-scoped server key before storage.
The same installation restores its Device within the same Account without enabling cross-account
correlation. Quota snapshot and Usage sequences are independent and are always recovered from
server control before upload.

### Usage replacement

Collectors return events plus a typed complete/partial coverage result for a UTC-hour range.
QuotaCLI aggregates only allowlisted billing dimensions into sparse hourly rows using a pinned
device IANA timezone. Complete coverage becomes an immutable outbox submission; partial coverage is
reported locally and never replaces remote rows. An accepted submission atomically replaces its
Device, agent, and UTC range. Empty complete coverage is a valid deletion of old facts in that
range.

Outbox retry reuses the same submission ID and sequence. The server records receipts so
crash-after-commit is a duplicate rather than double counting. Parser/timezone changes rebuild from
raw logs. A deletion watermark that cuts an hour causes the client to filter raw event instants and
rebuild only the post-watermark portion of that hour under the new Device generation.

Pricing is a versioned, effective-dated catalog served by QuotaRelay with ETag caching. The
runtime-neutral calculator in `@gotry-io/quota-model` resolves exact channel/model/date/dimension
matches. Missing or incomplete prices remain unpriced/partial; cost is not an invoice or subscription
spend.

## Package dependency rules

```text
                    quota-protocol
                 ┌──────┼──────────┐
                 ▼      ▼          ▼
           quota-model provider relay-core
                 ▲      │          │
                 └──────┴──► QuotaCLI

                            relay-core + protocol
                                      │
                                      ▼
                                Relay Worker ──► D1

QuotaBar ── bundled QuotaCLI output + Swift v2 models
Quota Web ── quota-protocol ── managed HTTP APIs
```

- `quota-protocol`, `quota-model`, and `relay-core` are runtime-neutral.
- `quota-provider` owns provider registration, local I/O, parser contracts, and collector
  implementations. It may use Node/Bun APIs and is imported only by QuotaCLI.
- `quota-model` owns quota transforms, Usage aggregation, and catalog/cost calculation; it does not
  perform I/O.
- `relay-core` exposes narrow Account and Usage state contracts; it does not import D1 or Hono.
- `apps/relay` is the only Cloudflare/D1 adapter and must not import filesystem, subprocess, TCP, or
  native-addon APIs.
- `apps/menubar` keeps Swift wire decoding and bundled-CLI invocation separate from SwiftUI views.

## Runtime responsibilities

### QuotaCLI

- `status` and provider configuration remain local-only.
- Account state lives outside the installation directory in the user configuration root. Files and
  the shared lock are owner-only, symlink-resistant, and atomically replaced.
- `login`, `logout`, `auth status`, `sync`, and `account` are the only account command surface.
- `sync` emits local quota and a local 30-day Usage report even while signed out. While signed in it
  refreshes authoritative Device control and the canonical pricing catalog, uploads a quota
  envelope, drains a bounded Usage outbox, and reads the account summary. A failed catalog refresh
  preserves the last valid cache.
- It has no daemon. QuotaBar schedules it on macOS; other platforms use an external scheduler.

### QuotaBar

- Ships its exact compatible QuotaCLI helper and never resolves a helper from `PATH`.
- Owns launch-at-login and the five-minute in-process refresh lifecycle; quitting stops recurring
  work.
- Presents local quota and Usage independently of account state, plus account status, Devices,
  optional account Usage, and login/logout actions from typed CLI JSON.
- Does not own OAuth, tokens, installation identity, upload sequence, cache, or outbox state.

### QuotaRelay

- Hono application mounted at `/oauth/v2` and `/api/v2`, plus health/readiness routes. Better Auth's
  standard handler is mounted at `/api/auth/v2`.
- Uses D1 migrations for Better Auth identity/Web sessions, Accounts, Devices, native
  sessions/grants, quota observations, hourly facts, coverage, receipts, and rate limits.
- Authenticates each route with an account, device, or browser principal and the minimum scope.
- Performs Device delete, Account delete, session rotation/revocation, and Usage replacement in
  storage transactions.
- Serves the canonical pricing catalog and account summaries; it never runs provider collectors.

### Quota Web

- Static Vite assets are built independently under `apps/web/dist` and served by the managed Worker.
- `/my` reads the account summary and manages quota, Usage, Devices, and Account deletion;
  `/activate` approves or denies a native device grant. The `/app` path shipped in 0.0.4 and is a
  single bookmark redirect to `/my`. Better Auth owns GitHub login, browser sign-out, and Account
  deletion. A deletion hook removes the corresponding Quota domain Account. Product-specific
  authorization and Device deletion require a recent browser session and an exact same-origin
  request.
- Production Web and Worker deploy together through `deploy-cloudflare.yml`; there is no separate
  website deployment or self-hosted bundle.

## Persistence and deployment

D1 is the only durable Relay store. Migration `0003_account_usage_v2.sql` intentionally removes the
unreleased owner/pairing schema; migration `0004_better_auth.sql` replaces the unreleased custom Web
identity/session tables with Better Auth and keeps QuotaCLI credentials separate. There is no
compatibility copy. See [ADR 0001](decisions/0001-persistent-relay-storage.md).

The checked-in Cloudflare workflow is the production deployment path. Local Worker builds use
Wrangler dry-run and local D1 migration verification. Manual remote migration or deployment is not a
development command.
