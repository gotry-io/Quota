# Architecture

This document defines Quota's system boundaries and data paths. Product status and commands live in
the root [`README.md`](../README.md); credential and retained-data rules live in
[`security.md`](security.md).

## Product boundaries

Quota has four application products and one shared Rust library boundary:

- QuotaBar is the macOS presentation product. Its app bundle contains one private Rust service;
  Swift owns views, preferences, accessibility, Launch at Login, and strict decoding only.
- QuotaCLI is a Linux-only native Rust command that uses the shared local service library. It is
  released as a static x86_64 binary; Windows is not supported.
- QuotaRelay owns GitHub-backed Accounts, Devices, scoped native sessions, normalized quota/Usage
  storage, deletion controls, pricing distribution, and account queries. Better Auth owns its Web
  identity/session boundary. Relay runs only as a Cloudflare Worker backed by D1.
- Quota Web owns the public site and browser account UI. It shares `quota.gotry.io` with the Worker
  but remains a separate Vite application and source boundary.

The bundled Rust executable is not a separate product: it has no command parser, terminal output,
socket, daemon mode, LaunchAgent, PATH lookup, or standalone distribution. QuotaBar is its parent,
transport peer, scheduler lifetime, and release boundary. `packages/service` contains the shared
provider, Usage, pricing, persistence, and Relay logic used by both Rust application entry points;
`apps/menubar/helper` supplies the private macOS stdio binary and `apps/cli` supplies the Linux-only
`quotacli` command.

GitHub is the only account identity provider. The managed origin is fixed at
`https://quota.gotry.io`. There is no anonymous owner, pairing group, arbitrary Relay URL, discovery
document, self-hosted process, SQLite Relay adapter, or protocol v1 route. The durable managed
boundary is [ADR 0006](decisions/0006-managed-account-device-usage.md); the local runtime decision is
[ADR 0007](decisions/0007-rust-native-local-service.md).

## Local runtime and IPC

```text
official provider sessions       agent JSON/JSONL logs
            │                            │
            └──────────────┬─────────────┘
                           ▼
                shared Rust service library
                 │        │            │
        providers.json  SQLite     managed HTTPS
                 │        │            │
                 └────────┴──────┬─────┘
                                 │ stdin/stdout NDJSON v1
                                 ▼
                          QuotaBar Swift UI
```

QuotaBar launches the fixed signed `Contents/Helpers/quota-service` path once. Requests, responses,
and state-change events are newline-delimited `snake_case` JSON with a 1 MiB line limit and request
IDs. Supported operations are state read, diagnose, refresh, login/cancel, logout, provider
configuration, and shutdown. `get_state` performs no collection or network work: it returns the
current SQLite-backed snapshot immediately. State components carry independent status, last-good
value, update time, error/recovery code, and refreshing flag for quota, Usage, account, and pricing.

The service begins a background startup refresh after IPC is available, emits revisioned
`state_changed` events, and schedules subsequent refreshes every five minutes. Manual refresh uses
the same single-flight path. stdin EOF or shutdown cancels work and terminates the service; no sync
continues after QuotaBar exits. A second installed client may acquire the same owner lock only after
the first process releases it; there is no multi-process coordination protocol beyond serialized
ownership.

The private `diagnose` operation is the single local health boundary for both products. It returns a
bounded, redacted report for the fixed capabilities `providers`, `quota`, `usage`, `pricing`,
`account`, and `sync`. QuotaBar exposes it from Settings as a copyable report; Linux `quotacli doctor`
renders the same service result as text or JSON. Neither client reads SQLite or source logs, and the
service never includes paths, raw provider output, prompts, completions, session identifiers,
credentials, tokens, or device identifiers. Report status is `healthy`, `degraded`, or `blocked`;
only `healthy` is a successful CLI exit. The lossless partition and partial-merge semantics are
canonical in [ADR 0008](decisions/0008-data-integrity-and-diagnostics.md).

Rust returns the merged Overview directly. Global fingerprints merge local and account-device
observations; source-scoped fingerprints remain separate. Selection favors a valid non-expired
observation, then newest observation time, then local source, then stable source ID. Swift never
reimplements this policy.

## Local collection and persistence

The provider catalog is the language-neutral `packages/provider/catalog.json`, validated by its JSON
Schema. Generation produces TypeScript protocol IDs, Rust catalog metadata under
`packages/service/src/catalog.rs`, and Swift `ProviderID`. The shared Rust crate implements all
seven quota collectors and all five Usage parsers; the macOS and Linux entry points call that crate.

Provider credentials remain provider-owned when available. Optional API-key provider overrides use
the released shared owner-only configuration root and `providers.json`; QuotaBar sends secrets only
over the child process's stdin, never argv or preferences. Environment variables remain supported
inputs. Operational state has one owner: `state.sqlite` stores installation/account state, component
last-good values, file index, normalized Usage facts, pricing state, sequences, and the durable
outbox. SQLite migrations are explicit and append-only.

Usage indexing is the final file-level invalidation design. Each refresh performs bounded source
discovery, records parser revision plus file identity, size, and modification time, skips unchanged
files, and transactionally replaces the normalized rows for changed files. Collectors return typed
complete/partial coverage. Complete coverage is partitioned losslessly at upload row/byte boundaries;
partial coverage is visible locally and never replaces remote facts. Invalid records are isolated at
record scope and unreadable files at file scope, so valid files and agents continue to upload. The
SQLite file index is the sole invalidation mechanism: no watcher or byte-checkpoint dependency is part
of the product. Model identifiers remain opaque bounded provider text, including punctuation, and
missing pricing never discards a valid fact.
Bounded Usage detail responses may explicitly mark truncated coverage, breakdown, or unpriced-model
detail; exact totals remain usable and clients surface that degradation.

On first launch, the one-time SQLite migration imports the released installation, session, Usage
cache, Usage outbox, and pricing cache exactly once. The import is transactional and idempotent;
source files are removed only after the new state is readable. The bounded released-client window
and removal checklist are defined in [ADR 0007](decisions/0007-rust-native-local-service.md). The
current shared `providers.json`/`ProviderConfigLock` path and OAuth `client_id=quotacli` are live
interfaces. The removed TypeScript/Bun runtime has no dual-read/write path or fallback.

## Managed account and sync

```text
GitHub ── Better Auth web OAuth ──► QuotaRelay ──► browser account session
                                          │
browser PKCE authorization                │ account + device token families
                                          ▼
Rust service ─ quota snapshots + hourly facts ─► D1
        ▲                                           │
        └──────── account summary / pricing ───────┘
                             │
                             ├──► QuotaBar
                             └──► Quota Web
```

The shared Rust service is the native OAuth public client used by QuotaBar and Linux `quotacli`.
QuotaBar uses Authorization Code with PKCE and a temporary loopback callback; Linux `quotacli` uses
the OAuth Device Authorization Grant and never opens a browser or loopback listener. Relay returns
separate account-read and current-device-write sessions; access and refresh expiry are explicit and
refresh rotates atomically. The network `client_id` value `quotacli` remains unchanged because it is
part of released protocol v2.

The random installation ID is HMACed with an account-scoped server key before storage. Quota and
Usage upload sequences are independent and recovered from authoritative Device control before
upload. Outbox retry reuses submission ID and sequence, making crash-after-commit a duplicate rather
than double counting. A deletion watermark rebuilds only permitted facts under the new Device
generation.

Pricing is versioned and effective-dated with ETag caching. Rust calculates local cost; Relay keeps
the equivalent server-side TypeScript calculation for account summaries. Exact
channel/model/date/dimension matching is required. Missing prices stay unpriced/partial; cost is not
an invoice or subscription spend.

## Source and dependency rules

```text
packages/provider/catalog.json
        ├──generated──► packages/service Rust crate
        ├──generated──► Swift QuotaBar
        └──generated──► protocol TypeScript IDs

apps/menubar/helper ──private IPC──► Swift QuotaBar
apps/cli ──native CLI──► packages/service

protocol + quota-model + relay-core
                │
                ├──► Relay Worker ──► D1
                └──► Quota Web
```

- `packages/service` owns shared local I/O, provider collection, Usage parsing/aggregation/pricing,
  OAuth, managed HTTP, scheduling, merging, and SQLite state.
- `apps/menubar/helper` is the macOS private stdio entry point and owns only process startup and IPC
  lifetime around `packages/service`.
- `apps/cli` is the Linux-only `quotacli` entry point and owns command parsing/terminal output around
  `packages/service`; its release boundary is the native x86_64 Linux binary.
- `apps/menubar` keeps private IPC/network-wire decoding separate from SwiftUI views and never reads
  local service files or provider-owned credentials.
- `packages/protocol` defines released managed-network contracts and exported JSON Schemas.
- `packages/protocol/fixtures/pricing-conformance.json` is the language-neutral pricing input and
  expected-output fixture consumed by both Rust service and TypeScript quota-model tests.
- `packages/quota-model` and `packages/relay-core` remain TypeScript runtime-neutral code used by
  Relay/Web; they are not imported by the local Rust service.
- `apps/relay` is the only Cloudflare/D1 adapter and must not import filesystem, subprocess, TCP, or
  native-addon APIs.
- `apps/web` remains a separate Vite source boundary even though production serves it and Relay from
  one hostname.

## Relay, Web, and deployment

QuotaRelay mounts Hono routes at `/oauth/v2` and `/api/v2`, Better Auth at `/api/auth/v2`, and health
routes at their documented paths. It authenticates each route with the minimum account, device, or
browser scope and performs Device/Account deletion, rotation/revocation, and Usage replacement in
storage transactions. Released 0.0.5 clients retain their bounded two-agent response variant only
through the completed 0.0.6/0.0.7 compatibility window. Current clients explicitly request all Usage
agents, and 0.0.8 contains no client-version response branch.

Quota Web builds static Vite assets independently. `/my` reads account summaries and manages
Devices and deletion; `/activate` approves or denies native authorization. Better Auth owns GitHub
login and browser sessions. Production Web and Worker deploy together only through
`.github/workflows/deploy-cloudflare.yml`.

D1 is the only durable Relay store and applied migrations are never rewritten. Local Worker builds
use Wrangler dry-run and local D1 migration verification. Manual remote migration or deployment is
not a development command.
