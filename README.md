# Quota

Quota is the monorepo behind [quota.gotry.io](https://quota.gotry.io). It keeps coding-agent
subscription quota and privacy-preserving Usage together across a user's devices.

- **Quota** — native iOS 17+ read-only Account viewer. It signs in with the registered `quota-ios`
  public client, reads remaining quota and Today Usage, and publishes a non-secret App Group
  snapshot for Home Screen and Lock Screen widgets.
- **QuotaBar** — native macOS menu-bar UI with a bundled private Rust service for local collection,
  durable state, account sync, and scheduling.
- **QuotaCLI** — Linux-only native Rust command that reuses the shared local service crate. It is
  released as a static x86_64 binary; Windows is not currently supported.
- **QuotaRelay** — managed account/device service on Cloudflare Workers and D1.
- **Quota Web** — public site, GitHub login, device authorization, and account dashboard.

Quota collection supports Codex, Claude Code, Grok, OpenRouter, DeepSeek, Kimi Code, LiteLLM, and
Cursor. Cursor prefers a signed-in Cursor.app session from local desktop state, then a stored
browser session. On macOS, QuotaBar can acquire that browser session for Cursor — the only provider
that declares one — and asks for consent before it reads a cookie.
Local Usage analytics supports Codex, Claude Code, Grok, OpenCode, Pi, and Cursor logs. Provider credentials,
prompts, completions, raw events, local paths, and conversation identifiers never upload.

Both collection clients expose the same service-owned report: Linux `quotacli doctor
[--format text|json] [--pretty]` and the QuotaBar Settings **Support** page on macOS. The report
lists the four user-visible surfaces — Quota Overview, this Mac's Usage, Account Usage, and Account
— and the sources behind them, each with one sentence naming what happened and what to do about it.
The service writes that sentence; the clients render it. Absent setup is inactive, not broken, and
Account data may fulfill Overview without a local provider login, but a local source this device
holds and cannot collect stays actionable. The report carries only safe provider and agent
identities, timestamps, and recovery codes: never credentials, tokens, local paths or filenames,
model lists, raw logs or responses, parser excerpts, prompts, completions, session identifiers, or
device identifiers. QuotaCLI exits nonzero when operation is not healthy, any surface's data is
stale or partial, or attention is required; healthy empty and automatic waiting states succeed.

## Architecture

QuotaBar starts a fixed signed `Contents/Helpers/quota-service` child and communicates over bounded,
versioned stdin/stdout NDJSON. The child announces `ready` once its local state is open, and
QuotaBar holds every request until then. Requests have no deadline of their own: a `ping` the child
answers without taking a lock is what says it is alive, and only a child that leaves two consecutive
pings unanswered is killed and replaced. The shared Rust service immediately returns its last valid
SQLite state, then collects provider quota, incrementally indexes Usage logs, refreshes pricing and
report-time model aliases, and synchronizes a signed-in account in the background. Its five-minute
scheduler exists only for the QuotaBar process lifetime, so quitting QuotaBar stops local work and
synchronization. Linux `quotacli` uses the same Rust service semantics through a native command-line
entry point.

Swift owns presentation, UI preferences, accessibility, and Launch at Login. Shared remaining-quota,
plan, count, cost, and compact-age copy lives in `packages/apple-shared`; wire decoding and Relay
access stay in each app or `packages/apple-client`. Rust owns provider and
Usage semantics, credentials, OAuth, Relay traffic, persistence, the durable Usage upload setting,
the hours it still owes an Account, the two-way merge of a resolved subscription against this Mac's
own reading, and scheduling. QuotaRelay and Quota Web
remain TypeScript. See the canonical
[architecture](docs/architecture.md), [security baseline](docs/security.md),
[provider strategies](docs/provider-collection.md),
[CodexBar platform capability baseline](docs/codexbar-platform-capabilities.md), [native service decision](docs/decisions/0007-rust-native-local-service.md),
[managed account decision](docs/decisions/0006-managed-account-device-usage.md),
[managed-data v6](docs/decisions/0024-hour-versioned-usage-and-daily-rollups.md),
[read-only iOS account client](docs/decisions/0013-readonly-ios-account-client.md),
[non-secret iOS widget snapshot](docs/decisions/0014-nonsecret-ios-widget-snapshot.md), and
[SvelteKit document Worker composition](docs/decisions/0011-sveltekit-document-worker.md), and
[one session system](docs/decisions/0025-one-session-system.md). The data
integrity contract is [ADR 0008](docs/decisions/0008-data-integrity-and-diagnostics.md),
report-time model identity is [ADR 0009](docs/decisions/0009-versioned-model-catalog.md),
the diagnostic report and the attempt journal behind it are
[ADR 0022](docs/decisions/0022-minimal-diagnostics.md), the split between an
identity store and a disposable cache is
[ADR 0021](docs/decisions/0021-identity-store-and-disposable-cache.md), and provider
browser-session authentication is
[ADR 0010](docs/decisions/0010-provider-browser-session-auth.md).

## Repository layout

```text
apps/cli/                  Linux-only native Rust quotacli command
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

Provider registration starts in `packages/provider/catalog.json`. Run
`pnpm generate:provider-catalog` after a catalog change to regenerate Rust, Swift, and TypeScript
provider IDs. Wire JSON uses `snake_case`. OAuth and Device control remain on v2; quota,
Usage, and Account summary use managed-data v6, the only data contract Relay serves. A Usage upload
replaces whole UTC hours by the version of the scan behind each one, and Relay folds them into the
daily rollup every read answers from
([ADR 0024](docs/decisions/0024-hour-versioned-usage-and-daily-rollups.md)).
Bundled private IPC v1 changes
atomically with QuotaBar. Its local Usage report carries scan status and coverage; state snapshots
carry precomputed period totals grouped by agent, then inference provider, then model. Summary totals are total, input,
output, cache-read input, cache-write input, reasoning, and usage-bearing output messages; sessions
are not collected.
The service precomputes Today, 7 Days, 30 Days, and All detail for This Mac and the signed-in Account,
so QuotaBar switches periods without collection or network work; Overview remains quota-only.
Catalog `account_sync` declares whether a provider synchronizes to the managed Account. The local
collection catalog may be broader than the set the Account accepts.

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

# Linux only: build and test the native QuotaCLI
pnpm build:linux-cli
pnpm test:linux-cli
```

The root `pnpm check`, `pnpm test`, and `pnpm build` commands cover the macOS service and QuotaBar
only; they intentionally do not compile the Linux-only CLI or the iOS app. Run the Linux commands on
Ubuntu (or another supported Linux host). Run the iOS commands on macOS. `pnpm test` runs every
Swift package, not only QuotaBar.

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

QuotaBar and QuotaCLI release on independent tags, coupled only by the repository `latest` alias
that QuotaBar distribution resolves through (see [architecture](docs/architecture.md)). A
`menubar-vX.Y.Z` tag builds one signed and notarized Apple Silicon app, a drag-install `.dmg`, a
Sparkle `appcast.xml` for in-app updates, and updates the Homebrew Cask. The Cask installs only
`QuotaBar.app`; it does not expose the private service as a command. Install with `brew install
gotry-io/tap/quotabar` or the website `.dmg`. A `cli-vX.Y.Z` tag publishes a static x86_64 Linux
binary and checksum to GitHub Releases. QuotaCLI is not published to npm or Homebrew; Windows is not
built or released.

```bash
pnpm version:bump:cli patch      # or minor | major | explicit semver
pnpm version:bump:menubar patch  # or minor | major | explicit semver
```

The marketing version lives in `apps/menubar/Support/Info.plist`.

## Current status

The repository implements protocol-v2 account/device authentication, a hand-written GitHub OAuth
sign-in whose browser session is one row in the same table the native clients use, managed-data v6, a registered
read-only `quota-ios` account OAuth client, a Quota iOS Connect Account / Today overview slice on
`packages/apple-client`, shared Apple presentation semantics in `packages/apple-shared`, a
non-secret App Group widget snapshot with an embedded WidgetKit extension, hour-versioned Usage
replacement with server-side daily rollups and resolved subscriptions,
D1 persistence and deletion watermarks, eight Rust quota collectors, six Rust
Usage parsers that read an appended log from where the last parse stopped, local hourly facts a scan
recomputes only where records moved, effective-dated cost calculation, owner-only
local SQLite state split into an identity store and a disposable cache, owner-only provider
configuration, persistent private IPC, QuotaBar account/provider
configuration UI, Sparkle in-app updates, fixed-window client-scoped account-or-local Usage
detail, shareable remaining-quota/usage exports, and the Web account dashboard. Raw model
identifiers remain opaque bounded provider text; a separately versioned catalog derives stable
report keys without rewriting facts or changing pricing. Valid facts remain usable when pricing or
model aliases are unknown. Record and file failures are isolated, and an hour carries the version of the scan behind it so a
retry is a comparison rather than a sequence to keep in step. The service-owned report says how each
surface is doing and which source explains it, in sentences the service writes, without treating
absent optional setup as failure. A seven-day bounded local attempt journal supplies the recent work
in a copied report and the canonical latest-attempt and latest-success facts; it is written
best-effort and never blocks the work it records. An Account device list reports only how recently
that device spoke — Active, Idle, or Not reporting — so no device asserts anything about another.
A cache SQLite cannot read is deleted and rebuilt by the next refresh
rather than salvaged; an identity it cannot read makes the Mac a new installation that asks to sign
in again.

Production GitHub OAuth and D1 deployment require the secrets documented by the managed Relay
configuration. The checked-in deployment workflow is the only authorized production path.

## License

Quota is MIT licensed with copyright attributed to `gotry-io contributors`.
