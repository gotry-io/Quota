# Quota

Quota is the monorepo behind [quota.gotry.io](https://quota.gotry.io). It keeps coding-agent
subscription quota and privacy-preserving Usage together across a user's devices.

- **QuotaBar** — native macOS menu-bar UI with a bundled private Rust service for local collection,
  durable state, account sync, and scheduling.
- **QuotaCLI** — Linux-only native Rust command that reuses the shared local service crate. It is
  released as a static x86_64 binary; Windows is not currently supported.
- **QuotaRelay** — managed account/device service on Cloudflare Workers and D1.
- **Quota Web** — public site, GitHub login, device authorization, and account dashboard.

Quota collection supports Codex, Claude Code, Grok, OpenRouter, DeepSeek, Kimi Code, LiteLLM, and
Cursor browser sessions on macOS.
Local Usage analytics supports Codex, Claude Code, Grok, OpenCode, Pi, and Cursor logs. Provider credentials,
prompts, completions, raw events, local paths, and conversation identifiers never upload.

Both native clients expose the same service-owned diagnostics: Linux `quotacli doctor
[--format text|json] [--pretty]` and the QuotaBar Settings **Diagnostics** action on macOS. The
report covers provider discovery and quota collection, Usage parsing/coverage, pricing, account
state, and synchronization. It contains bounded counters and safe recovery codes only; it never
includes credentials, tokens, local paths, raw logs, prompts, completions, session identifiers, or
device identifiers. A healthy report exits successfully; degraded or blocked state exits nonzero.

## Architecture

QuotaBar starts a fixed signed `Contents/Helpers/quota-service` child and communicates over bounded,
versioned stdin/stdout NDJSON. Each request has a fixed fifteen-second deadline; a timed-out child is
closed and the next request starts a fresh helper. The shared Rust service immediately returns its
last valid SQLite state, then collects provider quota, incrementally indexes Usage logs, refreshes
pricing and report-time model aliases, and synchronizes a signed-in account in the background. Its
five-minute scheduler exists only for the QuotaBar process lifetime, so quitting QuotaBar stops local
work and synchronization. Linux `quotacli` uses the same Rust service semantics through a native
command-line entry point.

Swift owns presentation, UI preferences, accessibility, and Launch at Login. Rust owns provider and
Usage semantics, credentials, OAuth, Relay traffic, persistence, the durable Usage upload setting,
outbox sequencing, merging local and account observations, and scheduling. QuotaRelay and Quota Web
remain TypeScript. See the canonical
[architecture](docs/architecture.md), [security baseline](docs/security.md),
[provider strategies](docs/provider-collection.md), [native service decision](docs/decisions/0007-rust-native-local-service.md),
[managed account decision](docs/decisions/0006-managed-account-device-usage.md), and
[SvelteKit document Worker composition](docs/decisions/0011-sveltekit-document-worker.md). The data
integrity and diagnostic contract is [ADR 0008](docs/decisions/0008-data-integrity-and-diagnostics.md),
report-time model identity is [ADR 0009](docs/decisions/0009-versioned-model-catalog.md), and
provider browser-session authentication is
[ADR 0010](docs/decisions/0010-provider-browser-session-auth.md).

## Repository layout

```text
apps/cli/                  Linux-only native Rust quotacli command
apps/menubar/             QuotaBar Swift 6.2 / SwiftUI app, including its private Rust helper
apps/relay/               Managed Hono Worker and D1 adapters
apps/web/                 Public site and authenticated account UI
packages/provider/        Language-neutral provider catalog and JSON Schema
packages/protocol/        Runtime schemas and exported network JSON Schemas
packages/service/         Shared Rust collection, Usage, pricing, and Relay logic
packages/quota-model/     Relay/Web runtime-neutral quota and pricing models
packages/relay-core/      Runtime-neutral account and Usage state contracts
docs/                     Architecture, security, provider, and decision records
```

Provider registration starts in `packages/provider/catalog.json`. Run
`pnpm generate:provider-catalog` after a catalog change to regenerate Rust, Swift, and TypeScript
provider IDs. Wire JSON uses `snake_case`. OAuth and Device control remain on released v2; quota,
Usage, and Account summary use managed-data v3. Released v2 data routes remain compatible and never
emit Cursor. Bundled private IPC v1 changes
atomically with QuotaBar. Its local Usage v3 report carries scan status and coverage; state snapshots
carry precomputed period totals grouped by client, then inference provider, then model. Summary totals are total, input,
output, cache-read input, cache-write input, reasoning, and usage-bearing output messages; sessions
are not collected.
The service precomputes Today, 7 Days, 30 Days, and All detail for This Mac and the signed-in Account,
so QuotaBar switches periods without collection or network work; Overview remains quota-only.
Catalog `account_sync` declares whether a provider synchronizes, while `account_sync_protocol`
records the first managed-data protocol that accepts it. Cursor starts at v3; v2 remains the closed
provider set shipped by menubar-v0.0.9.

## Development

Requirements: Node.js 24+, pnpm 10+, stable Rust, and Swift 6.2+ on macOS.

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
only; they intentionally do not compile the Linux-only CLI. Run the Linux commands on Ubuntu (or
another supported Linux host).

Useful entry points:

```bash
pnpm dev:web
pnpm dev:relay
cargo test --locked --package quota-service --package quota-menubar-helper
cargo test --locked --package quotacli
swift test --package-path apps/menubar
pnpm build:menubar:app
pnpm test:menubar:helper
```

Managed Relay and the website deploy together from `main` through
`.github/workflows/deploy-cloudflare.yml`. Local Wrangler dry runs are verification; do not apply
remote migrations or deploy manually without explicit authorization.

## Distribution

QuotaBar and QuotaCLI release independently. A `menubar-vX.Y.Z` tag builds one signed and notarized
Apple Silicon app, a drag-install `.dmg`, a Sparkle `appcast.xml` for in-app updates, and
updates the Homebrew Cask. The Cask installs only `QuotaBar.app`; it does not expose the private
service as a command. Install with `brew install gotry-io/tap/quotabar` or the website `.dmg`. A
`cli-vX.Y.Z` tag publishes a static x86_64 Linux binary and checksum to GitHub Releases. QuotaCLI is
not published to npm or Homebrew; Windows is not built or released.

```bash
pnpm version:bump:cli patch      # or minor | major | explicit semver
pnpm version:bump:menubar patch  # or minor | major | explicit semver
```

The marketing version lives in `apps/menubar/Support/Info.plist`.

## Current status

The repository implements protocol-v2 account/device authentication, managed-data v3, independent
quota and Usage upload sequencing, D1 persistence and deletion watermarks, eight Rust quota collectors, six Rust
Usage parsers with file-level incremental indexing, effective-dated cost calculation, owner-only
local SQLite state and provider configuration, persistent private IPC, QuotaBar account/provider
configuration UI, Sparkle in-app updates, fixed-window client-scoped account-or-local Usage
detail, shareable remaining-quota/usage exports, opt-in public `/u/{username}` pages, and the Web
account dashboard. Raw model
identifiers remain opaque bounded provider text; a separately versioned catalog derives stable
report keys without rewriting facts or changing pricing. Valid facts remain usable when pricing or
model aliases are unknown. Record/file failures are isolated and complete uploads are partitioned
losslessly, while partial scans do not replace remote facts. The service diagnostic report makes
every capability's status and safe counters observable.

Production GitHub OAuth and D1 deployment require the secrets documented by the managed Relay
configuration. The checked-in deployment workflow is the only authorized production path.

## License

Quota is MIT licensed with copyright attributed to `gotry-io contributors`.
