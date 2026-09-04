# Architecture

This document defines Quota's system boundaries and data paths. Product status and commands live in
the root [`README.md`](../README.md); credential, redaction, and retained-data rules live in
[`security.md`](security.md). Where a decision record owns a rule, this document names the shape and
links to it rather than restating it.

## Product boundaries

- **Quota** is the iOS 17+ presentation product. It signs in with the registered `quota-ios` public
  client, reads Account remaining quota and Today Usage, and publishes the non-secret App Group
  snapshot its widgets render. It is not a collection Device.
- **QuotaBar** is the macOS presentation product. Its bundle contains one private Rust service; Swift
  owns views, UI preferences, accessibility, Launch at Login, and wire decoding only.
- **QuotaRelay** owns GitHub-backed Accounts, Devices, one scoped session per client, normalized
  quota/Usage storage, deletion controls, pricing distribution, and account queries. It runs only as
  a Cloudflare Worker backed by D1.
- **Quota Web** owns the public site and browser account UI, sharing `quota.gotry.io` with the Worker
  as a separate SvelteKit application and source boundary.

The bundled Rust executable is not a separate product; QuotaBar is its parent, transport peer,
scheduler lifetime, and release boundary. `packages/service` holds the shared provider, Usage,
pricing, persistence, and Relay logic, and `apps/menubar/helper` is its only entry point: the
private macOS stdio binary. The crate itself stays platform-neutral, and its owner-only
configuration and state live under `~/.config/quota/`.

GitHub is the only account identity provider and the managed origin is fixed at
`https://quota.gotry.io`. There is no anonymous owner, pairing group, arbitrary Relay URL, discovery
document, self-hosted process, SQLite Relay adapter, or protocol v1 route. The decision records
behind each area are indexed by [`AGENTS.md`](../AGENTS.md) and linked where they apply below.

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
Operations are ping, state read, diagnose/recheck, refresh, cache reset, login/cancel, logout,
provider configuration, provider browser-session validate/commit/remove, Usage upload
configuration, and shutdown. The helper opens its local state first and then emits a `ready` event; it reads no request
before that, and QuotaBar sends none. It runs every operation but `ping` on one worker thread and
answers `ping` on the thread that reads stdin, so an operation that blocks never stops the helper
from saying it is alive. That is the only liveness signal QuotaBar uses: requests are never on a
deadline, and a helper leaving two consecutive pings unanswered is replaced.

`get_state` performs no collection or network work: it returns the current SQLite-backed snapshot,
including precomputed Today, 7 Days, 30 Days, and All Usage periods, immediately. Components carry
independent status, last-good value, update time, error/recovery code, and refreshing flag; there
are five of them — quota, Usage, account, pricing, and providers, the last of which a refresh never
touches and a configuration change always does. QuotaBar evaluates local notification rules in Swift
from the quota readings those events already carry; there is no notification IPC event and no sixth
component. The service begins a background startup refresh once IPC is available,
emits revisioned `state_changed` events, and then waits on one scheduler thread for the next of
three events: an Account conditional read every minute, a quota collection at the stored interval
(1, 2, 5, 10, or 15 minutes; default five), and a quota-only catch-up when a window `resets_at`
falls before the next collection. Usage indexes on the collection tick when the file index is
dirty, on its own in-flight lane, so a long scan does not postpone the next quota pass. An Account
poll that lands while Quota is already in flight is kept pending and starts when Quota finishes,
rather than being dropped for that minute. Manual refresh and Diagnostics Recheck run both lanes as
one coordinated refresh. A refresh applies a
component as soon as it has one rather than only at its end — the account read finishes in well
under a second, quota is applied and uploaded before Usage joins, and provider collection can
take twenty seconds per provider — and the end of a refresh applies a component exactly when it
differs from what was already published. QuotaBar sends `shutdown` as it terminates, waits at most two
seconds for the answer, and stdin EOF says the same thing to a helper that never gave one, so nothing
syncs after QuotaBar exits and a second client takes the owner lock only after the first releases it.

The private `diagnose` operation is the single local diagnostic boundary. Its `schema_version: 3`
report evaluates the fixed Quota Overview, This Device Usage, Account Usage, and Account surfaces,
then lists the sources behind them, each with one sentence the service writes. QuotaBar renders it
on the Diagnostics page; it reads no SQLite or source logs there and maps no code to copy of its own.
Diagnostics never evaluate a refresh in flight: the cache holds one completed report, replaced only
after quota, Usage, Account, pricing, Overview, and sync state have been applied, so `generated_at`
tells a caller whether a newer evaluation exists, and Recheck joins the single-flight refresh and
waits for a newer one. The contract, the attempt journal behind it, and its redaction are canonical
in [ADR 0022](decisions/0022-minimal-diagnostics.md).

Two independent facts decide whether an observation still describes current quota, and a reader needs
both ([ADR 0017](decisions/0017-derived-observation-freshness.md)). A device that fails to collect
republishes its own last reading with the status it found — `auth_required`, `unavailable`,
`unsupported`, or `error` — so a failure it detects becomes a fact every client shows at its next
refresh; the reading and its `observed_at` are untouched, because the numbers really are that old,
and only a reading still current is republished, which bounds the restatement. Time covers what
detection cannot, because a device that stopped collecting reports nothing at all: every observation
carries its own validity boundary — the first window reset it reports, its shortest window cadence
when it reports none, and at the latest a fixed maximum age — derived by each reader from the
snapshot rather than trusted from a stamp on it, so a reading of any age from any device in any
client version expires on the same terms. `packages/quota-model` owns the TypeScript rule,
`packages/apple-shared` the Swift one each Apple observation type answers by conforming, and
`packages/service`'s `observation` module the Rust one.

Relay keeps one observation per reporting device and resolves them on the read: an Account summary
answers `subscriptions[]`, one entry per subscription key carrying the chosen reading and every
`{device_id, observed_at}` behind it. That rule is stated once in
[ADR 0003](decisions/0003-observation-preserving-subscription-merge.md), implemented once in
`packages/quota-model`, and restated by no client. Global fingerprints merge across observation
sources and source-scoped fingerprints stay separate; selection favors a valid non-expired
observation, then newest observation time, then local source, then stable source ID — never when
Relay last wrote the row. QuotaBar merges twice rather than five ways: the resolved row against its
own local collection, the only authority for this device. Rust returns that merged Overview and Swift
never reimplements the policy. `quota-observation-conformance.json` states both rules as cases and
`wire-conformance.json` does the same for the contracts themselves: read contracts bind all three
runtimes, while a write is judged by the boundary schema that guards it — the sending side states
only bounds, and its types are held to the exported schema by test
([ADR 0019](decisions/0019-one-statement-per-contract.md),
[ADR 0023](decisions/0023-strict-writes-tolerant-reads.md),
[ADR 0028](decisions/0028-the-boundary-answers-the-write.md)).

## Local collection and persistence

The provider catalog is the language-neutral `packages/provider/catalog.json`, validated by its JSON
Schema; generation produces TypeScript protocol IDs, Rust catalog metadata in
`packages/service/src/catalog.rs`, and Swift `ProviderID`. The shared crate implements all eight
quota collectors and all six Usage parsers. `account_sync` declares whether a provider
synchronizes and the generated managed provider enum is exactly that set; all eight declare it
today, so the managed enum and the local collection schema currently name the same providers.
Provider credentials stay provider-owned; optional API-key overrides live in the owner-only `providers.json`
described in [`security.md`](security.md).

Operational state has one owner and two files
([ADR 0021](decisions/0021-identity-store-and-disposable-cache.md)). `identity.sqlite` stores what
this device cannot regenerate: installation, session, upload identity, the outbox of hours it still
owes an Account, the monotonic scan revision those hours carry, stored provider browser sessions, and
preferences including the Usage upload setting. The outbox is in that file because losing it would
lose hours already recomputed, not because it could not be rebuilt. `cache.sqlite` stores what it can: component
last-good values, the Usage file index and its normalized records, the hourly facts folded from them,
the fixed-period presentation cache, pricing and model catalog state, cached Account reads, the
last-completed diagnostic snapshot, and the bounded attempt journal. Both start at schema v1 with
explicit append-only migrations. A released single-file `state.sqlite` hands its identity rows over
once at startup and is then removed. Nothing derived crosses, because the first refresh rebuilds
it — and neither does its outbox: those were requests in a contract this build no longer speaks,
and the first scan recomputes every retained hour and sends it again.

Catalog browser-session capability contains an HTTPS login URL, exact Cookie hosts and names, a
browser-priority prefix, and `exclusive` when Settings should omit an official CLI sign-in command.
Cursor, Codex, Claude, Grok, and Kimi declare it, and for each of them the stored session is the
rung after every official credential rather than an alternative to one; Cursor still prefers a
signed-in Cursor.app session from local desktop state first. Swift acquires; Rust validates,
persists, and refreshes. Consent, redaction, and refusal are canonical in
[`security.md`](security.md) and [ADR 0010](decisions/0010-provider-browser-session-auth.md).

Usage indexing is file-level invalidation. Each refresh runs bounded source discovery, records parser
revision plus file identity, size, and modification time, and skips unchanged files. A file that only
grew is read from the byte its last parse stopped on, confirmed by a digest of the four kibibytes
before that point; a rewritten or truncated file fails that check and is read whole, and a parser
carrying context between lines never resumes. Invalid records are isolated at record scope and
unreadable files at file scope, so valid files and agents keep uploading, and the file index is the
sole invalidation mechanism: no watcher is part of the product.

The hour is the unit ([ADR 0024](decisions/0024-hour-versioned-usage-and-daily-rollups.md)). A scan
recomputes only the UTC hours whose records moved, folding each from the records this device retains,
and leaves an hour whose facts came out the same untouched. Each recomputed hour carries a monotonic
scan revision and an upload names whole hours carrying it, so Relay replaces an hour only for a
strictly newer scan and a retry is a comparison rather than a sequence. The upload identity a device
stages under is the account, device, generation, Relay's usage sync revision, and the deletion lower
bound; a change to any of them re-seeds every retained hour, so a device meeting an account for the
first time sends everything it holds, and Relay can ask for everything again by advancing the
revision it returns from `/api/v2/device/sync`. A scan that came up short
marks that hour `partial`, and a read reports a period `partial` when any hour behind it was. An hour
past 512 distinct rows folds its smallest into `other`, a period's agent tree folds its smallest model
leaves into `other` past 200, and a bounded read marks truncated unpriced-model detail with
`unpriced_truncated`. Exact totals stay usable, and clients surface the degradation.

The local Usage report is a private presentation contract carried inside the IPC state, so it names
no version of its own and moves with `ipc_version`. State snapshots separately carry the Today,
7 Days, 30 Days, and All summaries with exact totals, cost, and `agents[].providers[].models[]`
detail. `total_tokens` is input plus output; cache-read and cache-write tokens are named input
subsets; reasoning is an output subset; `messages` sums normalized usage-bearing model output facts
and is not a session count, because sessions are not collected. The Rust report groups facts by the
agent that emitted the usage, then each model under the vendor whose model it is, resolved from the
model's name by the model catalog's family rules — the agent and the billing channel never choose
that group, and a gateway is never one ([ADR 0009](decisions/0009-versioned-model-catalog.md)).
QuotaBar renders agent groups only on the Usage detail page; Overview stays quota-only.

Local periods fold from the hourly facts with SQL at refresh time, so no read loads the record
history. A local day begins at local midnight, so Today, 7 Days, and 30 Days are bounded by the
instants this device's own calendar puts around them — the rule the managed read follows, so both
sides of the panel agree. Signed-in Account
periods arrive in the one Account read and commit only as a complete set; QuotaBar reads them from
`get_state`, so changing the period performs no collection or network request. Collection and report
generation continue when Usage upload is disabled: the service neither stages nor drains the outbox,
`get_state` omits cached Account Usage so QuotaBar stays local-only, and quota and account
synchronization stay independent.

Report-time model normalization is a separate derived view over
`packages/protocol/catalog/model-catalog.json`: the vendor a model name belongs to by explicit family
prefix, then an exact `reported_model` plus vendor alias, never rewriting the raw text a fact was
collected with
([ADR 0009](decisions/0009-versioned-model-catalog.md)). Account summaries carry
`usage.agents[].providers[].models[]`, derived by Relay from retained normalized facts with the same
catalog so the row-level client, vendor, and model relationship survives across Devices; clients
never reconstruct ownership from independent breakdowns. Every billing channel Relay
stores is reported as stored — a client that cannot represent one has to update, which is not a
reason to rewrite facts on the way out. See [provider strategies](provider-collection.md) for the
provider ids that resolve each channel.

## Managed account and sync

The shared Rust service is the collection OAuth public client behind QuotaBar, and Authorization
Code with PKCE over a temporary loopback callback is the only grant it uses. Device `display_name`
is the host computer name (macOS ComputerName, otherwise hostname), reconciled by authenticated
device sync through the device-scoped profile endpoint, and the local session records the successful
profile so another write happens only after login, upgrade, or a host rename. Collection login
returns one session — a single access/refresh family that reads this Account and writes this Device,
with explicit expiry and compare-and-swap refresh rotation
([ADR 0027](decisions/0027-one-token-per-client.md)); a rotation whose successor was never
presented can be repeated with the token it replaced
([ADR 0030](decisions/0030-a-rotation-never-received-did-not-happen.md)). The `client_id` value is
`quotabar`. That exchange also answers with the Account's `display_label`, the same value the
Account read carries, so a client names the account it just reached without waiting for its first
read.

QuotaBar updates in place with Sparkle 2: it reads
`https://github.com/gotry-io/Quota/releases/latest/download/appcast.xml` and verifies EdDSA
signatures against the `SUPublicEDKey` in `Info.plist`, which the release workflow signs with
`SPARKLE_ED_PRIVATE_KEY`. Releases still publish `menubar-update.json` so QuotaBar 0.0.10 can update
once onto Sparkle. Both that appcast and the website `.dmg` button resolve through the repository
`latest` alias, which only a `menubar-v*` release carries — so the newest stable `menubar-v*` must
hold it.

The registered `quota-ios` public client uses the same `/oauth/v2/authorize` PKCE route with the
exact redirect `io.gotry.quota:/oauth/callback`. Its exchange rejects installation identity and
Device fields and returns only an account session: it is not a collection Device, is absent from
`PlatformSchema`, and never receives write authority. Quota iOS consumes that session through
`packages/apple-client` and fetches `GET /api/v6/account/summary`. The app process alone holds OAuth
and network authority — on screen and under the `io.gotry.quota.refresh` background app refresh, no
sooner than thirty minutes apart — and projects a non-secret `WidgetSnapshot` into App Group
`group.io.gotry.quota` for the `QuotaWidgets` extension, which reads only that file.

`GET /api/v6/account/summary` and `GET /api/v6/account/usage/activity` are conditional reads. Each
carries a strong `ETag` over an account version stamp, the request's full query string, the pricing
and model catalog revisions, and — for the summary — the caller's local date, because that is what
moves `today` with no write behind it. The stamp is a handful of aggregates over the devices and
observation rows the response projects, so a matching `If-None-Match` returns 304 before any Usage
query runs. The summary's Usage fold is stored keyed by what it depends on
([ADR 0031](decisions/0031-the-usage-fold-is-stored.md)): a matching key serves the stored fold,
and a miss folds and stores. The Rust service and the iOS client both read conditionally, storing each response with
its ETag in one transaction keyed by Account and treating a 304 as that stored response rather than a
failure; signing out drops the stored reads with the session.

The Account read is not sequenced behind local collection. It needs only the session, so a refresh
runs it beside provider collection and the Usage scan and applies the account component — and the
Account periods derived from it — the moment it lands, rather than when the whole refresh ends;
QuotaBar is told about it then too. What still runs after collection is the writing half of a sync:
the device control check, the quota upload, and the Usage outbox drain, in that order. Only a failure
there that ends the session speaks for the account, so an upload a refresh could not deliver never
takes back a summary it already read.

A refresh whose upload Relay actually accepted — a snapshot or an hour it did not already hold —
reads the Account once more before it ends, so what this Mac just sent appears in its own Account
view in the same refresh rather than five minutes later. That read is the same conditional one, so
an Account that did not move answers 304; an upload answered entirely with `ignored` changed nothing
and is not read back at all. Both reads publish through the same path, which applies a component only
when its value differs from the one already showing, so a re-read that says the same thing costs no
write and emits no event.

An Account-summary Device carries `last_seen_at` and `last_observed_at` and nothing it asserted about
itself. Clients derive how recently it spoke from the newer of the two — Active under thirty minutes,
Idle up to a day, Not reporting beyond that — because a quiet device is asleep, closed, or off rather
than broken ([ADR 0022](decisions/0022-minimal-diagnostics.md)).

Pricing is versioned and effective-dated with ETag caching. Rust calculates local cost and Relay
keeps the equivalent TypeScript calculation for account summaries, both requiring exact
channel/model/date/dimension matching. A row whose source never named a billing channel is still
valued at the vendor's official direct price when exact model or alias matching lands in exactly
one vendor-direct channel ([ADR 0029](decisions/0029-official-price-for-an-unnamed-channel.md)).
Every first-party client requests the `auto` cost mode, so a row the catalog cannot price falls
back to a complete source-reported cost and This Mac, Account, iOS, and Web report the same basis
for the same fact; `calculate` stays the route default for callers that do not ask. Costing
memoizes catalog validation by identity, and raw facts are priced before report grouping, so
normalization never creates a pricing alias or changes a cost outcome. Relay
publishes the model catalog at `GET /api/v2/model/catalog` with ETag validation and `public,
max-age=300, must-revalidate`; summaries carry its revision, the Rust client stores payload and ETag
atomically with a last-known-good cache, and a fetch failure never blocks collection, upload, totals,
or a report.

## Source and dependency rules

- `packages/provider/catalog.json` generates the Rust crate metadata, the Swift `ProviderID` enum in
  `packages/apple-client`, QuotaBar's app-behavior extension on that enum, and the protocol
  TypeScript IDs. One catalog produces one Swift type, and one decoder validates for both products.
- `packages/service` owns shared local I/O, provider collection, Usage parsing/aggregation/pricing,
  OAuth, managed HTTP, scheduling, merging, and SQLite state. `apps/menubar/helper` is its only
  entry point and adds only process startup and IPC lifetime around it.
- `apps/menubar` keeps private IPC decoding separate from SwiftUI views and never reads local service
  files or provider-owned credentials. It depends on `packages/apple-shared` for presentation
  semantics and on QuotaWire for the managed wire types and `ProviderID`, and must not depend on
  QuotaRelay or QuotaAccount, because the local service owns all Relay traffic for this product.
- `packages/apple-shared` owns reusable Apple presentation semantics over scalar inputs — remaining
  quota, plan and account labels, compact counts, Usage cost, compact relative age, the
  observation-freshness rule each snapshot type conforms to, and the subscription selector every
  Apple client hashes the same way. It depends on neither app and does not own `ProviderID`, decode
  wire types, network, persist, or reach Relay; `packages/apple-client` may depend on it so a wire
  type can answer a presentation question about itself. QuotaWire's `ProviderID` carries only
  providers that sync to an account, because a local-only collector there would force QuotaBar's
  enum to diverge again.
- `packages/apple-client` owns iOS account-read wire models, PKCE values, the fixed-origin Relay
  client, account session refresh/revoke, the last-good Account summary cache, and the
  Foundation-only `QuotaWidgetData` snapshot types and store. `apps/ios` owns SwiftUI,
  `ASWebAuthenticationSession`, App Group snapshot publish/clear, and the WidgetKit extension; its
  views do not call `URLSession` or Security or decode JSON. `QuotaWidgets` depends only on
  `QuotaWidgetData` and `QuotaPresentation`, and must not import `QuotaWire`, `QuotaRelay`,
  `QuotaAccount`, or Security, or use `URLSession` or Keychain.
- `packages/protocol` defines the managed-network contracts and exported JSON Schemas, including the
  language-neutral pricing and model-catalog fixtures both Rust and `quota-model` tests answer.
- `packages/quota-model` and `packages/relay-core` are runtime-neutral TypeScript for Relay and Web;
  the local Rust service does not import them. `apps/relay` is the only Cloudflare/D1 adapter and may
  not import filesystem, subprocess, TCP, or native-addon APIs, and `apps/web` stays a separate
  SvelteKit boundary meeting Relay only through `WebDocumentPort`.

## Relay, Web, and deployment

QuotaRelay mounts OAuth and Device control at `/oauth/v2` and `/api/v2`, the managed quota and Usage
data contract at `/api/v6`, browser sign-in and sign-out at `/api/auth`, and the health routes. It
authenticates each route with the minimum account, device, or browser scope and performs
Device/Account deletion, rotation/revocation, hour replacement with its daily rollup, and the
Usage-fold sweep in storage transactions. An Account read carries every stored agent and channel with no opt-in query: the only
thing it asks for is the caller's `tz`, because a local day begins at local midnight and that
decides where the three trailing periods start and end. Every route that reads a query names the
keys it accepts, and a key it did not name is a 400. The managed data contract is
canonical in [ADR 0024](decisions/0024-hour-versioned-usage-and-daily-rollups.md).

Quota Web is a SvelteKit app whose hashed `/_app/immutable/*` CSS and JS stay asset-first. Document
navigations run the Relay Worker first: `apps/relay/src/cloudflare.ts` stays Wrangler `main`, Hono
keeps `/api`, `/oauth`, `/healthz`, and `/readyz`, and every other Worker-first request is rendered
by SvelteKit `Server.respond`. The Worker reads the `__Host-quota_session` cookie through
`WebDocumentPort` and writes the signed-in header into the first HTML byte. `/` offers the QuotaBar
`.dmg` and Homebrew install command, GitHub sign-in is in the header, and `/my` is a server redirect
when unsigned and otherwise a streaming dashboard whose document load starts the existing
`GET /api/v6/account/summary` handler inside the composed Worker and reuses the request's memoized
session read, so Account data resolves in parallel with hydration without a second round trip. `/`
is public; every page that shows account data requires a session, Quota Web publishes none
anonymously, and `/app` redirects to `/my`. Relay owns GitHub login and browser
sessions ([ADR 0025](decisions/0025-one-session-system.md)); the composition decision is
[ADR 0011](decisions/0011-sveltekit-document-worker.md).

D1 is the only durable Relay store and applied migrations are never rewritten. Local Worker builds
use Wrangler dry-run and local D1 migration verification; production Web and Worker deploy together
only through `.github/workflows/deploy-cloudflare.yml`.
