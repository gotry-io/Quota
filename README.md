# Quota

Quota is the monorepo behind [quota.gotry.io](https://quota.gotry.io). It keeps coding-agent
subscription quota and privacy-preserving Usage together across a user's devices.

- **QuotaBar** — native macOS menu-bar UI with a bundled private Rust service for local collection,
  durable state, account sync, and scheduling.
- **QuotaCLI** — Linux-only native Rust command that reuses the shared local service crate. It is
  released as a static x86_64 binary; Windows is not currently supported.
- **QuotaRelay** — managed account/device service on Cloudflare Workers and D1.
- **Quota Web** — public site, GitHub login, device authorization, and account dashboard.

Quota collection supports Codex, Claude Code, Grok, OpenRouter, DeepSeek, Kimi Code, and LiteLLM.
Local Usage analytics supports Codex, Claude Code, Grok, OpenCode, and Pi logs. Provider credentials,
prompts, completions, raw events, local paths, and conversation identifiers never upload.

## Architecture

QuotaBar starts a fixed signed `Contents/Helpers/quota-service` child and communicates over bounded,
versioned stdin/stdout NDJSON. Each request has a fixed fifteen-second deadline; a timed-out child is
closed and the next request starts a fresh helper. The shared Rust service immediately returns its
last valid SQLite state, then collects provider quota, incrementally indexes Usage logs, refreshes
pricing, and synchronizes a signed-in account in the background. Its five-minute scheduler exists
only for the QuotaBar process lifetime, so quitting QuotaBar stops local work and synchronization.
Linux `quotacli` uses the same Rust service semantics through a native command-line entry point.

Swift owns presentation, preferences, accessibility, and Launch at Login. Rust owns provider and
Usage semantics, credentials, OAuth, Relay traffic, persistence, outbox sequencing, merging local and
account observations, and scheduling. QuotaRelay and Quota Web remain TypeScript. See the canonical
[architecture](docs/architecture.md), [security baseline](docs/security.md),
[provider strategies](docs/provider-collection.md), [native service decision](docs/decisions/0007-rust-native-local-service.md),
and [managed account decision](docs/decisions/0006-managed-account-device-usage.md).

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
provider IDs. Wire JSON uses `snake_case`. Managed network protocol v2 remains compatible with
released clients; bundled private IPC v1 changes atomically with QuotaBar.

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
Apple Silicon app and updates the Homebrew Cask. The Cask installs only `QuotaBar.app`; it does not
expose the private service as a command. A `cli-vX.Y.Z` tag publishes a static x86_64 Linux binary
and checksum to GitHub Releases. QuotaCLI is not published to npm or Homebrew; Windows is not built
or released.

```bash
pnpm version:bump:cli patch      # or minor | major | explicit semver
pnpm version:bump:menubar patch  # or minor | major | explicit semver
```

The marketing version lives in `apps/menubar/Support/Info.plist`.

## Current status

The repository implements protocol v2 account/device authentication, independent quota and Usage
upload sequencing, D1 persistence and deletion watermarks, seven Rust quota collectors, five Rust
Usage parsers with file-level incremental indexing, effective-dated cost calculation, owner-only
local SQLite state and provider configuration, persistent private IPC, QuotaBar account/provider
configuration UI, and the Web account dashboard. Unknown prices remain visibly unpriced; partial
scans do not replace remote facts.

Production GitHub OAuth and D1 deployment require the secrets documented by the managed Relay
configuration. The checked-in deployment workflow is the only authorized production path.

## License

Quota is MIT licensed with copyright attributed to `gotry-io contributors`.
