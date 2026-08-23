# Architecture

This document defines Quota's system boundaries and data paths. Product status and commands live in
the root [`README.md`](../README.md); credential and retained-data rules live in
[`security.md`](security.md).

## Product boundaries

Quota has five application products and three shared native library boundaries:

- Quota is the iOS 17+ presentation product. It signs in with the registered `quota-ios` public
  client and reads Account remaining quota and Today Usage. Home Screen and Lock Screen widgets
  render a non-secret App Group snapshot published by the app; the extension never collects or
  uploads. It is not a collection Device.
- QuotaBar is the macOS presentation product. Its app bundle contains one private Rust service;
  Swift owns views, UI preferences, accessibility, Launch at Login, and strict decoding only. The
  Rust service owns the durable Usage upload setting so it applies before background work begins.
- QuotaCLI is a Linux-only native Rust command that uses the shared local service library. It is
  released as a static x86_64 binary; Windows is not supported.
- QuotaRelay owns GitHub-backed Accounts, Devices, scoped native sessions, normalized quota/Usage
  storage, deletion controls, pricing distribution, and account queries. Better Auth owns its Web
  identity/session boundary. Relay runs only as a Cloudflare Worker backed by D1.
- Quota Web owns the public site and browser account UI. It shares `quota.gotry.io` with the Worker
  but remains a separate SvelteKit application and source boundary.

The bundled Rust executable is not a separate product: it has no command parser, terminal output,
socket, daemon mode, LaunchAgent, PATH lookup, or standalone distribution. QuotaBar is its parent,
transport peer, scheduler lifetime, and release boundary. `packages/service` contains the shared
provider, Usage, pricing, persistence, and Relay logic used by both Rust application entry points;
`apps/menubar/helper` supplies the private macOS stdio binary and `apps/cli` supplies the Linux-only
`quotacli` command. `packages/apple-client` is the shared Apple wire, fixed-origin Relay, session,
last-good cache, and non-secret widget-snapshot boundary consumed by Quota iOS. `packages/apple-shared`
is the Foundation-only presentation package consumed by QuotaBar, Quota iOS, the Quota widget
extension, and `packages/apple-client` for remaining-quota, plan/account label, compact count,
Usage cost, compact relative-age text, and the observation-freshness rule each snapshot type
conforms to. It does not decode protocol or app wire types, own ProviderID, network, persist, or
access Relay. QuotaBar still owns its Swift IPC and network-wire models; those types stay out of
both Apple packages.

GitHub is the only account identity provider. The managed origin is fixed at
`https://quota.gotry.io`. There is no anonymous owner, pairing group, arbitrary Relay URL, discovery
document, self-hosted process, SQLite Relay adapter, or protocol v1 route. The durable managed
boundary is [ADR 0006](decisions/0006-managed-account-device-usage.md); managed-data v3 is
[ADR 0012](decisions/0012-managed-data-v3.md); the read-only iOS account client is
[ADR 0013](decisions/0013-readonly-ios-account-client.md); the non-secret iOS widget
snapshot is [ADR 0014](decisions/0014-nonsecret-ios-widget-snapshot.md); the local runtime decision is
[ADR 0007](decisions/0007-rust-native-local-service.md); diagnostic attempts, Support Report, and
Device Health are [ADR 0015](decisions/0015-diagnostic-attempts-and-device-health.md).

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
IDs. Supported operations are state read, diagnose/recheck, refresh, login/cancel, logout, provider
configuration, provider browser-session validate/commit/remove, Usage upload configuration, and
shutdown. Browser-session validate is non-mutating; commit revalidates and transactionally replaces
the Rust-owned SQLite session. `get_state` performs no collection or
network work: it returns the current SQLite-backed snapshot, including precomputed Today, 7 Days,
30 Days, and All Usage periods, immediately. State components carry
independent status, last-good value, update time, error/recovery code, and refreshing flag for quota,
Usage, account, and pricing.

The service begins a background startup refresh after IPC is available, emits revisioned
`state_changed` events, and schedules subsequent refreshes every five minutes. Manual refresh uses
the same single-flight path. stdin EOF or shutdown cancels work and terminates the service; no sync
continues after QuotaBar exits. A second installed client may acquire the same owner lock only after
the first process releases it; there is no multi-process coordination protocol beyond serialized
ownership.

The private `diagnose` operation is the single local diagnostic boundary for both products. Its v2
report evaluates the fixed user-visible Quota Overview, This Device Usage, Account Usage, and Account
surfaces, then explains them with source checks and root-cause findings. Checks distinguish
`this_device`, `account`, and `system` work and whether each path is inactive, opportunistic, or
required. QuotaBar exposes the report from Settings; Linux `quotacli doctor` renders the same service
result as text or JSON. Neither client reads SQLite or source logs or reimplements policy.

Diagnostics never evaluate a refresh in flight. Migration v7 stores one completed report snapshot;
after every refresh, the service replaces it only after quota, Usage, Account, pricing, Overview, and
sync state have been applied. While another refresh runs, `diagnose` returns that completed snapshot
with current `running` phase/start metadata. QuotaBar Recheck starts or joins the real single-flight
refresh and waits for a newer completed revision, bounded by its UI wait. The service never includes
paths, filenames, raw provider output, parser excerpts, model lists, prompts, completions, session or
device identifiers, credentials, or tokens. The evaluator and exact v2 semantics are canonical in
[ADR 0008](decisions/0008-data-integrity-and-diagnostics.md). Migration v8's structured attempt
journal supplies full retained latest-attempt/latest-success facts and the bounded recent activity
projection; its retention and redaction are canonical in
[ADR 0015](decisions/0015-diagnostic-attempts-and-device-health.md).

Every collected snapshot is stamped with `valid_until` at the collection boundary: the first window
reset it reports, and at the latest a fixed maximum age. That instant is what expires an
observation, locally and after upload. It is derived from the observation rather than reported by a
provider, so it is computed once for every collector.

Rust returns the merged Overview directly. Global fingerprints merge local and account-device
observations; source-scoped fingerprints remain separate. Account observations this device uploaded
are dropped before the merge, because local collection is the only authority for this device:
reading its own upload back would keep a rejected or removed local source on screen as another
device's report. Selection favors a valid non-expired observation, then newest observation time,
then local source, then stable source ID. Swift never reimplements this policy. Quota iOS, its widgets,
and the website read account observations without that merge, so they apply the same expiry
themselves: `packages/quota-model` owns the TypeScript rule and `packages/apple-shared` owns the
Swift one, which each Apple observation type answers by conforming rather than by restating. A
device that sleeps or loses a provider sign-in therefore stops presenting its last counters as
current anywhere.

## Local collection and persistence

The provider catalog is the language-neutral `packages/provider/catalog.json`, validated by its JSON
Schema. Generation produces TypeScript protocol IDs, Rust catalog metadata under
`packages/service/src/catalog.rs`, and Swift `ProviderID`. The shared Rust crate implements all
eight quota collectors and all six Usage parsers; the macOS and Linux entry points call that crate.

Provider credentials remain provider-owned when available. Optional API-key provider overrides use
the released shared owner-only configuration root and `providers.json`; QuotaBar sends secrets only
over the child process's stdin, never argv or preferences. Environment variables remain supported
inputs. Operational state has one owner: `state.sqlite` stores installation/account state, component
last-good values, file index, normalized Usage facts, fixed-period presentation cache, pricing state,
sequences, the durable outbox and Usage upload setting, and the single last-completed diagnostic
snapshot plus bounded structured attempt journal. Unreadable or unwritable image handling and repair
presentation are [ADR 0016](decisions/0016-local-service-self-repair.md). SQLite migrations are
explicit and append-only.

Catalog browser-session capability contains an HTTPS login URL, exact Cookie hosts/names, a
browser-priority prefix, and `exclusive` when Settings should omit an official CLI sign-in command.
Cursor still prefers a signed-in Cursor.app session from local desktop state before that stored
browser session. QuotaBar
pins login and discovery to one selected supported browser;
SweetCookieKit only acquires allowlisted Cookie candidates in Swift memory. Rust owns syntax and
account validation, durable state, provider networking, and routine refresh. Linux QuotaCLI does
not implement browser acquisition.

The local provider catalog is broader than each managed protocol. Catalog `account_sync` declares
whether a provider synchronizes, and `account_sync_protocol` records the first managed-data version
that accepts it. Generated v2 IDs remain the closed set shipped by menubar-v0.0.9; generated v3 IDs
add Cursor. New clients upload Cursor only to v3, while Relay keeps v2 routes isolated and filters
Cursor from their responses. The private local collection schema continues to use the full catalog.
The local SQLite v6 migration handles the shipped v2-to-v3 cutover: v2 Usage outbox payloads are
promoted in place because v3 preserves their identity, sequence, coverage, and row invariants, while
the derived v2 Account summary and Account period caches are discarded and rebuilt from Relay. Raw
indexed Usage facts, provider state, sessions, quota, and upload identity are not removed. Migration
v7 adds only the replaceable last-completed diagnostics snapshot used by `diagnose`; migration v8
adds the seven-day/50,000-completed-row diagnostic attempt journal and clears only the derived
pre-Device-Health Account summary so strict upgraded clients cannot receive its old Device shape.

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

The local Usage report is a private v3 presentation contract, separate from managed-data v3 facts
and account summaries. It carries collection status, coverage, timezone, and the
model-catalog revision. State snapshots separately carry the precomputed Today, 7 Days, 30 Days, and
All summaries, each with exact totals, cost, and `clients[].providers[].models[]` detail. `total_tokens` is input plus output;
cache-read and cache-write tokens are named input subsets; reasoning is an output subset; and
`messages` is the sum of normalized usage-bearing model output facts. It is not a session count, and
sessions are not collected. The Rust report first groups facts by the agent client that emitted the
usage, then groups each model under the inference provider derived from the fact's billing channel;
client and model text never choose or override that provider. QuotaBar renders client groups only on
the Usage detail page; Overview remains quota-only. The local SQLite migration discards only
incompatible derived Usage presentations; indexed facts and the managed outbox remain intact and
rebuild the current v3 report on refresh.

Local periods are folded from the indexed facts once; signed-in Account periods use the dedicated
Relay Usage Summary route and are committed
only as a complete set. QuotaBar reads these values from `get_state`, so opening Usage and changing
the period performs no collection or network request.

Local collection and report generation continue when Usage upload is disabled. The service neither
stages nor drains the managed Usage outbox while disabled; pending local work is retained and resumes
after re-enabling. `get_state` omits cached Account Usage while disabled so QuotaBar stays local-only.
Quota and account synchronization remain independent.

Report-time model normalization is a separate derived view. The language-neutral source of truth is
`packages/protocol/catalog/model-catalog.json`, with the generated
`packages/protocol/schema/model-catalog-v1.json` artifact. Rust and Relay match only an exact
`reported_model` + inference `provider` alias, with optional agent `client` and UTC effective-date
bounds; there are no regex, case, trim, fuzzy, or guessed aliases. Raw model text remains unchanged in SQLite,
Usage uploads, and D1. A catalog update therefore regroups existing raw rows the next time a report
is built, without reparsing source files or rewriting fact rows. Resolved model breakdown keys use
the stable canonical ID; unresolved rows retain their raw model text.

Current native clients opt into `usage.clients[].providers[].models[]` on v3 account summaries with
`usage_clients=1`. Relay derives this account-wide structure directly from retained normalized facts,
preserving the row-level client, billing-channel provider, and model relationship across Devices.
The field remains omitted without the opt-in. It never appears on released v2 summaries unless a v2
client explicitly requests it, and v2 still excludes Cursor. Clients never reconstruct ownership
from independent breakdowns or model text.

Billing channels added after menubar-v0.0.19 use the same shape, because that release already
speaks v3 and cannot be separated by a protocol version. Summary and hourly responses narrow a
newer channel to `unknown` unless the client sends `usage_channels=1`.
[ADR 0012](decisions/0012-managed-data-v3.md) owns that rule; see
[provider strategies](provider-collection.md) for the registered provider ids that resolve each
channel.

The native-cutover import and its version-specific Relay behavior ended in 0.0.8 as defined by
[ADR 0007](decisions/0007-rust-native-local-service.md). Applied SQLite migrations remain ordered
history; the current shared `providers.json`/`ProviderConfigLock` path and OAuth
`client_id=quotacli` are live interfaces. The removed TypeScript/Bun runtime has no dual-read/write
path or fallback.

## Managed account and sync

```text
GitHub ── Better Auth web OAuth ──► QuotaRelay ──► browser account session
                                          │
browser PKCE authorization                │ account + device token families
quota-ios PKCE (account session only)     │
                                          ▼
Rust service ─ quota snapshots + hourly facts + latest Device Health ─► D1
        ▲                                           │
        └──────── account summary / pricing ───────┘
                             │
                             ├──► QuotaBar
                             ├──► Quota Web
                             └──► Quota iOS account reads
```

The shared Rust service is the native collection OAuth public client used by QuotaBar and Linux
`quotacli`.
QuotaBar uses Authorization Code with PKCE and a temporary loopback callback; Linux `quotacli` uses
the OAuth Device Authorization Grant and never opens a browser or loopback listener. Device
`display_name` is the host computer name (macOS ComputerName, otherwise hostname), not the product
name. Authenticated device sync reconciles that name and platform through the device-scoped profile
endpoint; the local session records the successful profile so another write occurs only after login,
upgrade, or a host-name change. QuotaBar uses Sparkle 2 for in-app updates. The packaged app reads
`https://github.com/gotry-io/Quota/releases/latest/download/appcast.xml` and verifies EdDSA
signatures with the `SUPublicEDKey` embedded in `Info.plist`. The release workflow signs the
notarized `.dmg` with the `SPARKLE_ED_PRIVATE_KEY` repository secret. Releases still publish
`menubar-update.json` so QuotaBar 0.0.10 can update once onto Sparkle. The repository `latest`
release alias is a QuotaBar distribution surface: both that appcast and the website `.dmg` button
resolve through it, and only a `menubar-v*` release carries either asset. The newest stable
`menubar-v*` release must therefore hold `latest`, so every other release train publishes without
claiming it. Collection login returns separate account-read and current-device-write sessions;
access and refresh expiry are explicit and refresh rotates atomically. The network `client_id` value
`quotacli` remains unchanged because it is part of released protocol v2.

The registered public client `quota-ios` uses the same GitHub identity and `/oauth/v2/authorize`
PKCE route with the exact redirect `io.gotry.quota:/oauth/callback`. Its token exchange rejects
installation identity and Device fields and returns only an account session. It is not a collection
Device, is absent from `PlatformSchema`, and never receives snapshot or Usage write authority. Quota
iOS consumes that session through `packages/apple-client` and fetches
`GET /api/v3/account/summary?device_health=1` for Today and read-only Device Health. The app process
alone holds OAuth and network authority.
After a trusted summary is available it projects a non-secret `WidgetSnapshot` into the App Group
`group.io.gotry.quota` for the embedded `QuotaWidgets` extension; the extension reads only that
protected file and never calls Relay. See
[ADR 0013](decisions/0013-readonly-ios-account-client.md) and
[ADR 0014](decisions/0014-nonsecret-ios-widget-snapshot.md).

The random installation ID is HMACed with an account-scoped server key before storage. Quota and
Usage upload sequences are independent and recovered from authoritative Device control before
upload. Outbox retry reuses submission ID and sequence, making crash-after-commit a duplicate rather
than double counting. A deletion watermark rebuilds only permitted facts under the new Device
generation. Disabling Usage upload is a local Device preference: native Usage presentation becomes
local-only, while already uploaded account history remains subject to the existing Device and Account
deletion controls.

After an authenticated Device completes a refresh, the service uploads a sanitized health snapshot
on change or a bounded heartbeat. The Device token determines the row; D1 stores only the latest
monotonic revision and uses server receipt time for freshness. QuotaBar, Quota Web, and Quota iOS
request the strict `device_health=1` Account-summary shape and display health, version, platform, and
last report/refresh/sync. The shipped default managed-data v3 response remains unchanged. A report
older than the freshness window means only not recently active. Upload failure is local diagnostic
evidence and does not fail collection or synchronization. See
[ADR 0015](decisions/0015-diagnostic-attempts-and-device-health.md).

Pricing is versioned and effective-dated with ETag caching. Rust calculates local cost; Relay keeps
the equivalent server-side TypeScript calculation for account summaries. Exact
channel/model/date/dimension matching is required. Every first-party client requests the `auto`
cost mode, so a row the catalog cannot price falls back to a complete source-reported cost and This
Mac, Account, iOS, and Web report the same basis for the same fact; `calculate` remains the route
default for callers that do not ask. Costing memoizes catalog validation by identity, so a
long-lived catalog is scanned once rather than per request. Missing prices stay unpriced/partial;
cost is not an invoice or subscription spend. Model normalization is intentionally independent: raw facts are
priced before report grouping, and normalization never creates pricing aliases or changes a cost or
unpriced outcome.

QuotaRelay publishes the model catalog independently at `GET /api/v2/model/catalog`, with ETag
validation and `public, max-age=300, must-revalidate` caching. Account summaries include the catalog
revision only for current clients that explicitly opt in with `model_catalog=1`; strict older
requests receive no new field. The Rust client stores the payload and ETag atomically with a
last-known-good cache. Catalog fetch failure never blocks collection, upload, totals, or a report.

## Source and dependency rules

```text
packages/provider/catalog.json
        ├──generated──► packages/service Rust crate
        ├──generated──► Swift QuotaBar
        ├──generated──► Swift packages/apple-client
        └──generated──► protocol TypeScript IDs

apps/menubar/helper ──private IPC──► Swift QuotaBar
apps/cli ──native CLI──► packages/service
packages/apple-shared ──presentation──► Swift QuotaBar
packages/apple-shared ──presentation──► Quota iOS
packages/apple-shared ──presentation──► QuotaWidgets
packages/apple-client ──HTTPS──► Quota iOS (app only)
packages/apple-client QuotaWidgetData ──App Group snapshot──► QuotaWidgets

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
  local service files or provider-owned credentials. It depends on `packages/apple-shared` for
  presentation text only and must not depend on QuotaWire, QuotaRelay, or QuotaAccount.
- `packages/apple-shared` owns reusable Apple presentation semantics with scalar inputs. QuotaBar and
  Quota iOS map their own models onto those inputs. The package does not depend on
  `packages/apple-client` or either app. QuotaBar local/provider IDs and the released iOS Account
  `ProviderID` stay in their current owners because their future admissible sets differ.
- `packages/apple-client` owns iOS account-read wire models, PKCE values, the fixed-origin Relay
  client, account session refresh/revoke, last-good Account summary cache, and the Foundation-only
  `QuotaWidgetData` snapshot types/store. `apps/ios` owns SwiftUI, `ASWebAuthenticationSession`, App
  Group snapshot publish/clear, and the embedded WidgetKit extension. App views do not call
  `URLSession`, Security, or decode JSON. `QuotaWidgets` depends only on `QuotaWidgetData` and
  `QuotaPresentation`; it must not import `QuotaWire`, `QuotaRelay`, `QuotaAccount`, or Security, and
  must not use `URLSession` or Keychain.
- `packages/protocol` defines released managed-network contracts and exported JSON Schemas.
- `packages/protocol/fixtures/pricing-conformance.json` is the language-neutral pricing input and
  expected-output fixture consumed by both Rust service and TypeScript quota-model tests.
- `packages/protocol/catalog/model-catalog.json` is the language-neutral report-time model catalog;
  its schema is generated from `ModelCatalogSchema` and consumed by both Rust and TypeScript.
- `packages/quota-model` and `packages/relay-core` remain TypeScript runtime-neutral code used by
  Relay/Web; they are not imported by the local Rust service.
- `apps/relay` is the only Cloudflare/D1 adapter and must not import filesystem, subprocess, TCP, or
  native-addon APIs.
- `apps/web` remains a separate SvelteKit source boundary even though production serves it and Relay
  from one hostname. SvelteKit owns documents, routes, and document-scoped viewer presentation.
  Relay owns Better Auth, OAuth, APIs, D1, Usage aggregation, and domain policy. The two meet only
  through `WebDocumentPort`.

## Relay, Web, and deployment

QuotaRelay mounts OAuth and Device control at `/oauth/v2` and `/api/v2`, quota/Usage managed data at
both compatible `/api/v2` and current `/api/v3` routes, Better Auth at `/api/auth/v2`, and health
routes including self-owned `/api/v3/device/health`. It authenticates each route with the minimum
account, device, or browser scope and performs Device/Account deletion, rotation/revocation, and
Usage replacement in storage transactions. Relay serves the current Usage agents and pricing
catalog without the ended 0.0.5 response variant; current clients explicitly send
`usage_agents=all`.

Quota Web is a SvelteKit app. Hashed `/_app/immutable/*` CSS and JS stay asset-first. Document
navigations run the existing Relay Worker first: `apps/relay/src/cloudflare.ts` stays Wrangler
`main`, Hono keeps `/api`, `/oauth`, `/healthz`, and `/readyz`, and every other Worker-first
request is rendered by SvelteKit `Server.respond`. The Worker reads the Better Auth session
cookie through `WebDocumentPort` and writes the signed-in header into the first HTML byte.
Session cookies remain HttpOnly. `/` offers the QuotaBar `.dmg` and Homebrew install command.
GitHub sign-in is in the header; `/my` is a server redirect when unsigned and otherwise a
streaming dashboard. Its document load starts the existing
`GET /api/v3/account/summary?device_health=1` handler inside the composed Worker and reuses the
request's memoized Better Auth session, so Account data can resolve in parallel with hydration
without a second browser round trip. The API schema and Relay/Web source boundary remain unchanged.
`/u/{username}` is the public projection for that GitHub username. `/activate` approves or
denies native authorization. `/app` is a server redirect to `/my`. Better Auth owns GitHub
login and browser sessions. Production Web and Worker deploy together only through
`.github/workflows/deploy-cloudflare.yml`. The composition decision is
[ADR 0011](decisions/0011-sveltekit-document-worker.md).

D1 is the only durable Relay store and applied migrations are never rewritten. Local Worker builds
use Wrangler dry-run and local D1 migration verification. Manual remote migration or deployment is
not a development command.

The shipped compatibility and route split are canonical in
[ADR 0012](decisions/0012-managed-data-v3.md); latest-only Device Health storage is canonical in
[ADR 0015](decisions/0015-diagnostic-attempts-and-device-health.md).
