# Quota

Quota is the monorepo behind [quota.gotry.io](https://quota.gotry.io). It keeps coding-agent
subscription quota and privacy-preserving Usage together across a user's devices.

- **Quota** — native iOS 17+ read-only Account viewer. It signs in with the registered `quota-ios`
  public client, reads remaining quota and Today Usage, and publishes a non-secret App Group
  snapshot for Home Screen and Lock Screen widgets.
- **QuotaBar** — native macOS menu-bar UI with a bundled private Rust service for local collection,
  durable state, account sync, and scheduling.
- **QuotaRelay** — managed account/device service on Cloudflare Workers and D1.
- **Quota Web** — public site, GitHub sign-in, and account dashboard.

Quota collection supports Codex, Claude Code, Grok, OpenRouter, DeepSeek, Kimi Code, LiteLLM, and
Cursor; local Usage analytics supports Codex, Claude Code, Grok, OpenCode, Pi, and Cursor logs.
Provider credentials, prompts, completions, raw events, local paths, and conversation identifiers
never upload. Codex, Claude Code, Grok, Kimi Code, and Cursor can each be read from a browser
session as their ladder's last rung, and QuotaBar asks before it opens a cookie store — see
[security baseline](docs/security.md).

The QuotaBar Settings **Support › Diagnostics** page renders one service-owned report. It lists the four
user-visible surfaces — Quota Overview, this Mac's Usage, Account Usage, and Account — and the
sources behind them, each with one sentence naming what happened and what to do about it. The
service writes that sentence; QuotaBar renders it
([ADR 0022](docs/decisions/0022-minimal-diagnostics.md)).

## Architecture

QuotaBar starts a fixed signed `Contents/Helpers/quota-service` child and communicates over bounded,
versioned stdin/stdout NDJSON. The child announces `ready` once its local state is open, and
QuotaBar holds every request until then. Requests have no deadline of their own: a `ping` the child
answers without taking a lock is what says it is alive, and only a child that leaves two consecutive
pings unanswered is killed and replaced. The Rust service immediately returns its last valid state,
then collects provider quota, incrementally indexes Usage logs, refreshes pricing and report-time
model aliases, and synchronizes a signed-in account in the background. Its five-minute scheduler
lives only for the QuotaBar process lifetime, so quitting QuotaBar stops local work and
synchronization.

Swift owns presentation, UI preferences, accessibility, and Launch at Login; shared remaining-quota,
plan, count, cost, and compact-age copy lives in `packages/apple-shared`, and wire decoding and Relay
access in each app or `packages/apple-client`. Rust owns provider and Usage semantics, credentials,
OAuth, Relay traffic, persistence, and scheduling. QuotaRelay and Quota Web are TypeScript.

The canonical documents are [architecture](docs/architecture.md),
[security baseline](docs/security.md), [provider strategies](docs/provider-collection.md), and
[CodexBar platform capabilities](docs/codexbar-platform-capabilities.md);
[`AGENTS.md`](AGENTS.md) indexes the decision records behind each area.

## Repository layout

```text
apps/ios/                 Quota iPhone/iPad SwiftUI account app
apps/menubar/             QuotaBar Swift 6.2 / SwiftUI app, including its private Rust helper
apps/relay/               Managed Hono Worker and D1 adapters
apps/web/                 Public site and authenticated account UI
packages/apple-client/    Shared Apple wire, Relay, session, last-good cache, and widget-snapshot modules
packages/apple-shared/    Foundation-only Apple presentation semantics for QuotaBar, Quota iOS, and widgets
packages/provider/        Language-neutral provider catalog and JSON Schema
packages/protocol/        Runtime schemas and exported network JSON Schemas
packages/service/         Shared Rust collection, Usage, pricing, and Relay logic
packages/quota-model/     Relay/Web runtime-neutral quota and pricing models
packages/relay-core/      Runtime-neutral account and Usage state contracts
docs/                     Architecture, security, provider, and decision records
```

Provider registration starts in `packages/provider/catalog.json`; run
`pnpm generate:provider-catalog` after a catalog change to regenerate the Rust, Swift, and
TypeScript provider IDs. Wire JSON uses `snake_case`. OAuth and Device control remain on v2, while
quota, Usage, and Account summary use managed-data v6, the only data contract Relay serves. Bundled
private IPC v1 changes atomically with QuotaBar; the local Usage report and state snapshots ride
that version rather than naming their own. Summary totals are total, input, output, cache-read
input, cache-write input, reasoning, and usage-bearing output messages; sessions are not collected.
The service precomputes Today, 7 Days, 30 Days, and All detail for This Mac and the signed-in
Account, so QuotaBar switches periods without collection or network work; Overview stays quota-only.

## Development

Requirements: Node.js 24+, pnpm 10+, stable Rust, and Swift 6.2+ on macOS. Quota iOS also needs
Xcode with Swift 6.2 and the iOS 17+ SDK, plus the installed XcodeGen CLI to regenerate its
checked-in project.

```bash
pnpm install
pnpm format:check
pnpm check
pnpm test
pnpm build
```

The root `pnpm check`, `pnpm test`, and `pnpm build` commands cover the macOS service and QuotaBar
only; they intentionally do not compile the iOS app. Run the iOS commands on macOS. `pnpm test`
runs every Swift package, not only QuotaBar.

`pnpm install` arms the checked-in hooks in `.githooks` through `core.hooksPath`. Pre-commit
rejects unformatted sources and a stale generated provider catalog; pre-push runs the tests for the
areas the pushed commits touch. Bypass either with `QUOTA_HOOKS_SKIP=1` or `--no-verify`.

Useful entry points:

```bash
pnpm dev:web
pnpm dev:relay
pnpm test:service
pnpm test:swift
pnpm generate:ios
pnpm test:ios
pnpm build:ios
pnpm build:menubar:app
pnpm test:menubar:helper
```

Managed Relay and the website deploy together from `main` through
`.github/workflows/deploy-cloudflare.yml`. Local Wrangler dry runs are verification; do not apply
remote migrations or deploy manually without explicit authorization.

## Distribution

QuotaBar is the only released product, and it resolves updates through the repository `latest`
alias (see [architecture](docs/architecture.md)). A `menubar-vX.Y.Z` tag builds one signed and
notarized Apple Silicon app, a drag-install `.dmg`, a Sparkle `appcast.xml` for in-app updates, and
updates the Homebrew Cask. The Cask installs only `QuotaBar.app`; it does not expose the private
service as a command. Install with `brew install gotry-io/tap/quotabar` or the website `.dmg`.

```bash
pnpm version:bump:menubar patch  # or minor | major | explicit semver
```

The marketing version lives in `apps/menubar/Support/Info.plist`.

## Current status

The menu bar shows the tightest remaining percentage across the subscriptions Overview still counts
as current, and Overview closes with a Today line for spend and tokens. Local state is two
owner-only SQLite files: an identity store holding what this Mac cannot regenerate, and a cache that
is deleted and rebuilt rather than repaired when SQLite refuses to read it. The bundled helper
announces `ready` when that state is open and answers `ping` while it works, so QuotaBar waits on
what the child says rather than on a clock. `diagnose` answers one `schema_version: 3` report —
four surfaces, the sources behind them, and up to 100 recent attempts — and no device asserts
anything about another.

Managed data is v6. A Usage upload names whole UTC hours carrying the version of the scan behind
each one, Relay replaces an hour only for a strictly newer scan and folds the days it touched into a
rollup every read answers from, and an Account summary resolves subscriptions once so an account
collected on three Macs reads as one subscription everywhere. Relay owns GitHub sign-in itself
through a hand-written OAuth round trip, and every client — browser, QuotaBar, iOS — holds one
session in one table, scoped by what that client is for
([ADR 0027](docs/decisions/0027-one-token-per-client.md)).
Five providers can fall back to a browser session as their last rung, behind a consent sheet and
an explicit access-denied outcome. Quota iOS refreshes its Account and republishes its widget snapshot in the
background as well as on screen.

Around those: eight Rust quota collectors, six Usage parsers that read an appended log from where
the last parse stopped, local hourly facts a scan recomputes only where records moved,
effective-dated cost calculation with a separately versioned model catalog that regroups reports
without rewriting facts, a registered read-only `quota-ios` client, Sparkle in-app updates, and the
Web account dashboard. Valid facts stay usable when pricing or model aliases are unknown, and record
and file failures are isolated.

Production GitHub OAuth and D1 deployment require the secrets documented by the managed Relay
configuration. The checked-in deployment workflow is the only authorized production path.

## License

Quota is MIT licensed with copyright attributed to `gotry-io contributors`.
