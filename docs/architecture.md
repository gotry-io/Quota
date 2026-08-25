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
  Swift owns views, UI preferences, accessibility, Launch at Login, and wire decoding only. The
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
access Relay. QuotaBar reads the managed wire types — quota, account, and Usage — and
`ProviderID` from `QuotaWire`, and generates its app-only provider behavior as an extension on that
enum, so one catalog produces one Swift type and one decoder validates for both products. It still
owns its private IPC models and its Usage upload and local-report types, which no other Apple
product speaks; those stay out of both Apple packages.

GitHub is the only account identity provider. The managed origin is fixed at
`https://quota.gotry.io`. There is no anonymous owner, pairing group, arbitrary Relay URL, discovery
document, self-hosted process, SQLite Relay adapter, or protocol v1 route. The durable managed
boundary is [ADR 0006](decisions/0006-managed-account-device-usage.md); managed-data v6 is
[ADR 0024](decisions/0024-hour-versioned-usage-and-daily-rollups.md); the read-only iOS account client is
[ADR 0013](decisions/0013-readonly-ios-account-client.md); the non-secret iOS widget
snapshot is [ADR 0014](decisions/0014-nonsecret-ios-widget-snapshot.md); the local runtime decision is
[ADR 0007](decisions/0007-rust-native-local-service.md); the diagnostic report and the attempt
journal behind it are [ADR 0022](decisions/0022-minimal-diagnostics.md).

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
and events are newline-delimited `snake_case` JSON with a 1 MiB line limit and request IDs.
Supported operations are ping, state read, diagnose/recheck, refresh, login/cancel, logout, provider
configuration, provider browser-session validate/commit/remove, Usage upload configuration, and
shutdown. The helper opens its local state first and then emits a `ready` event; it reads no request
before that, and QuotaBar sends none. It runs every operation but `ping` on one worker thread and
answers `ping` on the thread that reads stdin, so an operation that blocks — a provider round trip,
a state lock held by a refresh — never stops the helper from saying it is alive. That is the only
liveness signal QuotaBar uses: requests themselves are never on a deadline. Browser-session validate
is non-mutating; commit revalidates and transactionally replaces the Rust-owned SQLite session.
`get_state` performs no collection or network work: it returns the current SQLite-backed snapshot,
including precomputed Today, 7 Days, 30 Days, and All Usage periods, immediately. State components
carry independent status, last-good value, update time, error/recovery code, and refreshing flag for
quota, Usage, account, and pricing.

The service begins a background startup refresh after IPC is available, emits revisioned
`state_changed` events, and schedules subsequent refreshes every five minutes. Manual refresh uses
the same single-flight path. stdin EOF or shutdown cancels work and terminates the service; no sync
continues after QuotaBar exits. A second installed client may acquire the same owner lock only after
the first process releases it; there is no multi-process coordination protocol beyond serialized
ownership.

The private `diagnose` operation is the single local diagnostic boundary for both products. Its
`schema_version: 3` report evaluates the fixed user-visible Quota Overview, This Device Usage,
Account Usage, and Account surfaces, then lists the sources behind them — a provider on this device,
a Usage agent, the account, the upload path, the pricing catalog, local state. Each row carries one
sentence the service writes naming what happened and what to do. QuotaBar renders it on the Support
page; Linux `quotacli doctor` renders the same service result as text or JSON. Neither client reads
SQLite or source logs, and neither maps a code to copy of its own.

Diagnostics never evaluate a refresh in flight. The cache stores one completed report snapshot; after
every refresh, the service replaces it only after quota, Usage, Account, pricing, Overview, and sync
state have been applied. While another refresh runs, `diagnose` returns that completed snapshot
unchanged, so its `generated_at` is what tells a caller whether a newer evaluation exists. QuotaBar
Recheck starts or joins the real single-flight refresh and waits for a newer `generated_at`, bounded
by its UI wait. The service never includes paths, filenames, raw provider output, parser excerpts,
model lists, prompts, completions, session or device identifiers, credentials, or tokens. The bounded
attempt journal supplies the latest-attempt and latest-success facts and the recent work a copied
report lists; it is written best-effort and never blocks the collection it records. The report
contract, the journal's retention, and its redaction are canonical in
[ADR 0022](decisions/0022-minimal-diagnostics.md).

Two independent facts decide whether an observation still describes current quota, and a reader
needs both. A device that fails to collect republishes its own last reading with the status it
found — `auth_required`, `unavailable`, `unsupported`, or `error` — so a failure it detects becomes
a fact every client shows at its next refresh instead of one they wait out; the reading and its
`observed_at` are untouched, because the numbers really are that old, and the status returns to
`available` when collection recovers. Only a reading that is still current is republished, which is
also what bounds it: the restatement is no longer `available`, so it is no longer current and cannot
be restated again. A reading that already aged out says nothing new, because every reader reached
that verdict from the reading itself.

Time covers what detection cannot: a device that stopped collecting entirely reports nothing at
all. Every observation therefore carries its own validity boundary — the first window reset it
reports, its shortest window cadence when it reports no reset, and at the latest a fixed maximum
age. Every input is part of the reading, so each reader derives the boundary from the snapshot
instead of trusting one stamped onto it: a reading uploaded by any device, of any age, in any client
version expires on the same terms. `packages/quota-model` owns the TypeScript rule,
`packages/apple-shared` owns the Swift one, which each Apple observation type answers by conforming
rather than by restating, and `packages/service`'s `observation` module owns the Rust one. A snapshot
carrying the retired `valid_until` stamp is refused at the wire boundary rather than ignored.

Relay keeps one observation per reporting device and resolves them on the read: an Account summary
answers `subscriptions[]`, one entry per subscription key carrying the chosen reading and every
`{device_id, observed_at}` behind it. The rule is stated once in
[ADR 0003](decisions/0003-observation-preserving-subscription-merge.md), implemented once in
`packages/quota-model`, and no client restates it. Global fingerprints merge across observation
sources; source-scoped fingerprints remain separate per source. Selection favors a valid
non-expired observation, then newest observation time, then local source, then stable source ID —
never when Relay last wrote the row, which a device re-uploading a reading it already knows moves
without making that reading newer. QuotaBar merges twice, not five ways: the resolved row against
its own local collection, because local collection is the only authority for this device. Rust
returns that merged Overview directly and Swift never reimplements the policy.
`packages/protocol/fixtures/quota-observation-conformance.json` states both rules as cases, and the
Relay and Rust implementations each answer that file.
`wire-conformance.json` does the same for the contracts themselves, so a payload one runtime
starts accepting cannot pass unnoticed by the others; see
[ADR 0019](decisions/0019-one-statement-per-contract.md). A device
that sleeps or loses a provider sign-in therefore stops presenting its last counters as current
anywhere, and an account collected on several Macs reads as one subscription everywhere.

## Local collection and persistence

The provider catalog is the language-neutral `packages/provider/catalog.json`, validated by its JSON
Schema. Generation produces TypeScript protocol IDs, Rust catalog metadata under
`packages/service/src/catalog.rs`, and Swift `ProviderID`. The shared Rust crate implements all
eight quota collectors and all six Usage parsers; the macOS and Linux entry points call that crate.

Provider credentials remain provider-owned when available. Optional API-key provider overrides use
the released shared owner-only configuration root and `providers.json`; QuotaBar sends secrets only
over the child process's stdin, never argv or preferences. Environment variables remain supported
inputs. Operational state has one owner and two files
([ADR 0021](decisions/0021-identity-store-and-disposable-cache.md)). `identity.sqlite` stores what
this device cannot regenerate: installation, session, upload identity, the durable outbox, stored
provider browser sessions, and preferences including the Usage upload setting. `cache.sqlite` stores
what it can: component last-good values, the Usage file index and normalized facts, the fixed-period
presentation cache, pricing and model catalog state, cached Account reads, the single last-completed
diagnostic snapshot, and the bounded attempt journal. A cache SQLite refuses to read is deleted and
rebuilt by the next refresh, and `get_state` reports `cache.rebuilding` until one complete Usage scan
has run; an identity it refuses makes the device a new installation. Both schemas start at v1 and
migrations are explicit and append-only.

Catalog browser-session capability contains an HTTPS login URL, exact Cookie hosts/names, a
browser-priority prefix, and `exclusive` when Settings should omit an official CLI sign-in command.
Cursor still prefers a signed-in Cursor.app session from local desktop state before that stored
browser session. QuotaBar
pins login and discovery to one selected supported browser;
SweetCookieKit only acquires allowlisted Cookie candidates in Swift memory. Rust owns syntax and
account validation, durable state, provider networking, and routine refresh. Linux QuotaCLI does
not implement browser acquisition.

The local provider catalog is broader than the managed Account. Catalog `account_sync` declares
whether a provider synchronizes, and the generated managed provider enum is exactly that set. The
private local collection schema continues to use the full catalog.
A released single-file `state.sqlite` is imported into `identity.sqlite` once at startup — its
installation, session, upload context, outbox, browser sessions, and Usage upload preference — and
the released image is then removed. Nothing else comes across, because everything else it held is
rebuilt by the first refresh.

Usage indexing is the final file-level invalidation design. Each refresh performs bounded source
discovery, records parser revision plus file identity, size, and modification time, skips unchanged
files, and transactionally replaces the normalized rows for changed files. Invalid records are
isolated at record scope and unreadable files at file scope, so valid files and agents continue to
upload. The SQLite file index is the sole invalidation mechanism: no watcher or byte-checkpoint
dependency is part of the product. Model identifiers remain opaque bounded provider text, including
punctuation, and missing pricing never discards a valid fact.
An upload names whole UTC hours and each one carries the version of the scan behind it, so a scan
that came up short is marked `partial` on the hour it describes rather than on a window beside it;
see [ADR 0024](decisions/0024-hour-versioned-usage-and-daily-rollups.md). A managed read reports
`partial` for a period when any hour behind it was scanned incompletely.
Bounded Usage responses may still explicitly mark truncated unpriced-model detail, and a period's
agent tree folds its smallest model leaves into `other` past 200 of them; exact totals remain
usable and clients surface that degradation.

The local Usage report is a private presentation contract carried inside the IPC state, so it names
no version of its own and moves with `ipc_version`. It carries collection status, coverage,
timezone, and the model-catalog revision. State snapshots separately carry the precomputed Today, 7 Days, 30 Days, and
All summaries, each with exact totals, cost, and `agents[].providers[].models[]` detail. `total_tokens` is input plus output;
cache-read and cache-write tokens are named input subsets; reasoning is an output subset; and
`messages` is the sum of normalized usage-bearing model output facts. It is not a session count, and
sessions are not collected. The Rust report first groups facts by the agent that emitted the
usage, then groups each model under the inference provider derived from the fact's billing channel;
agent and model text never choose or override that provider. QuotaBar renders agent groups only on
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

Account summaries carry `usage.agents[].providers[].models[]`. Relay derives this account-wide
structure directly from retained normalized facts,
preserving the row-level client, billing-channel provider, and model relationship across Devices.
Clients never reconstruct ownership from independent breakdowns or model text.

Every billing channel Relay stores is reported as stored. A client that cannot represent a channel
it does not know is a client that has to update, not a reason to rewrite facts on the way out; see
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
Rust service ─── quota snapshots + hourly facts ───────────────────► D1
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
`GET /api/v6/account/summary` for Today and the read-only device list. The app process
alone holds OAuth and network authority.
After a trusted summary is available it projects a non-secret `WidgetSnapshot` into the App Group
`group.io.gotry.quota` for the embedded `QuotaWidgets` extension; the extension reads only that
protected file and never calls Relay. See
[ADR 0013](decisions/0013-readonly-ios-account-client.md) and
[ADR 0014](decisions/0014-nonsecret-ios-widget-snapshot.md).

The random installation ID is HMACed with an account-scoped server key before storage. Uploads
carry no sequence: a quota reading is placed by `(provider, fingerprint)` and ordered by the instant
it was observed, and an hour of Usage is replaced only by a scan whose `scan_version` is strictly
newer than the stored one. A retry is therefore a comparison rather than a write, and
crash-after-commit needs nothing remembered. A deletion watermark rebuilds only permitted facts
under the new Device generation; an hour before it is `ignored`. Disabling Usage upload is a local
Device preference: native Usage presentation becomes local-only, while already uploaded account
history remains subject to the existing Device and Account deletion controls.

`GET /api/v6/account/summary` and `GET /api/v6/account/usage/activity` are conditional reads. Each
carries a strong `ETag` over an account version stamp, the request's full query string, the pricing
and model catalog revisions, and — for the summary — the caller's local date, because that is what
moves `today` with no write behind it. Both are `Cache-Control: private, no-cache` so a caller may
hold the body as long as it revalidates. The stamp is a handful of aggregates over the devices and
quota observation rows the response projects; a matching `If-None-Match` returns 304 before any
Usage query runs. Document and `__data.json` responses stay `private, no-store`.

The Rust service and the Quota iOS client both read conditionally. Each stores the response with
the ETag it is current at in one transaction, keyed by Account, and treats a 304 as that stored
response rather than as a failure: the account component keeps the value the previous read
produced. Signing out drops the stored reads with the session.

An Account-summary Device carries `last_seen_at` and `last_observed_at` and nothing it asserted
about itself. Clients derive how recently it spoke from the newer of the two: Active under thirty
minutes, Idle up to a day, Not reporting beyond that. A quiet device is asleep, closed, or off, which is not a claim that it is broken. See
[ADR 0022](decisions/0022-minimal-diagnostics.md).

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
revision. The Rust client stores the payload and ETag atomically with a
last-known-good cache. Catalog fetch failure never blocks collection, upload, totals, or a report.

## Source and dependency rules

```text
packages/provider/catalog.json
        ├──generated──► packages/service Rust crate
        ├──generated──► Swift packages/apple-client (enum)
        ├──generated──► Swift QuotaBar (app-behavior extension)
        └──generated──► protocol TypeScript IDs

apps/menubar/helper ──private IPC──► Swift QuotaBar
apps/cli ──native CLI──► packages/service
packages/apple-shared ──presentation──► Swift QuotaBar
packages/apple-shared ──presentation──► Quota iOS
packages/apple-shared ──presentation──► QuotaWidgets
packages/apple-client QuotaWire ──wire types + ProviderID──► Swift QuotaBar
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
- `apps/menubar` keeps private IPC decoding separate from SwiftUI views and never reads local
  service files or provider-owned credentials. It depends on `packages/apple-shared` for
  presentation semantics and on QuotaWire for the managed wire types and `ProviderID`; it must not
  depend on QuotaRelay or QuotaAccount, because the local service owns all Relay traffic for this
  product. Its own models are the private IPC types, the Usage upload and local-report types, and
  the generated app-only provider behavior.
- `packages/apple-shared` owns reusable Apple presentation semantics with scalar inputs, and does not
  depend on either app. `packages/apple-client` may depend on it so a wire type can answer a
  presentation question about itself. QuotaWire's `ProviderID` carries only providers that sync to an
  account; a local-only collector would have no case there and would force QuotaBar's enum to
  diverge again.
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

QuotaRelay mounts OAuth and Device control at `/oauth/v2` and `/api/v2`, the managed quota and
Usage data contract at `/api/v6`, Better Auth at `/api/auth/v2`, and the health routes. It
authenticates each route with the minimum account, device, or browser scope and performs
Device/Account deletion, rotation/revocation, and hour replacement with its daily rollup in storage
transactions. An Account read carries every stored agent and channel with no opt-in query; only the
released pricing-catalog route still accepts the `usage_agents=all` marker its clients send.

Quota Web is a SvelteKit app. Hashed `/_app/immutable/*` CSS and JS stay asset-first. Document
navigations run the existing Relay Worker first: `apps/relay/src/cloudflare.ts` stays Wrangler
`main`, Hono keeps `/api`, `/oauth`, `/healthz`, and `/readyz`, and every other Worker-first
request is rendered by SvelteKit `Server.respond`. The Worker reads the Better Auth session
cookie through `WebDocumentPort` and writes the signed-in header into the first HTML byte.
Session cookies remain HttpOnly. `/` offers the QuotaBar `.dmg` and Homebrew install command.
GitHub sign-in is in the header; `/my` is a server redirect when unsigned and otherwise a
streaming dashboard. Its document load starts the existing
`GET /api/v6/account/summary` handler inside the composed Worker and reuses the
request's memoized Better Auth session, so Account data can resolve in parallel with hydration
without a second browser round trip. The API schema and Relay/Web source boundary remain unchanged.
Every page requires a session; Quota Web publishes no account data anonymously. `/activate` approves
or denies native authorization. `/app` is a server redirect to `/my`. Better Auth owns GitHub
login and browser sessions. Production Web and Worker deploy together only through
`.github/workflows/deploy-cloudflare.yml`. The composition decision is
[ADR 0011](decisions/0011-sveltekit-document-worker.md).

D1 is the only durable Relay store and applied migrations are never rewritten. Local Worker builds
use Wrangler dry-run and local D1 migration verification. Manual remote migration or deployment is
not a development command.

The managed data contract is canonical in
[ADR 0024](decisions/0024-hour-versioned-usage-and-daily-rollups.md).
