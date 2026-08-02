# Quota

Quota is the monorepo behind [quota.gotry.io](https://quota.gotry.io), monitoring coding-agent
subscription quotas.

- **QuotaBar** — native macOS menu bar app for local and remote quotas.
- **QuotaCLI** — standalone local collector and installable edge agent.
- **QuotaRelay** — persistent device registry and normalized snapshot relay.

The initial providers are Codex, Claude Code, and Grok.

## Architecture

QuotaCLI collects provider quota locally and emits normalized snapshots; provider credentials never
cross its process boundary. QuotaBar consumes local results directly and may read remote snapshots
through a persistent QuotaRelay.

The canonical system description is in [architecture](docs/architecture.md). See the
[security baseline](docs/security.md), [provider strategies](docs/provider-collection.md),
[persistent storage decision](docs/decisions/0001-persistent-relay-storage.md), and
[product design system](DESIGN.md) for their respective concerns.

## Repository layout

```text
apps/web/                Quota public website and static Cloudflare assets
apps/menubar/            QuotaBar Swift 6.2 / SwiftUI app
apps/cli/                QuotaCLI TypeScript / Bun executable
apps/relay/              Hono Relay for Workers+D1 and Bun+SQLite
packages/protocol/       Runtime schemas and language-neutral JSON Schemas
packages/quota-model/    Runtime-neutral quota calculations
packages/provider-core/  Provider interfaces without Node dependencies
packages/provider-node/  Filesystem, process, and credential discovery for QuotaCLI
packages/relay-core/     Persistent Relay state contract
deploy/                  Self-hosted container configuration
docs/                    Architecture, security, and decision records
```

All TypeScript packages use the `@gotry/*` namespace. Wire JSON remains `snake_case`; Swift models
decode it through a shared codec.

## Development

Requirements: Node.js 24+, pnpm 10+, Bun 1.3+, and Swift 6.2+ on macOS.

```bash
pnpm install
pnpm check
pnpm test
pnpm build
```

Run the self-hosted Relay with persistent SQLite storage:

```bash
QUOTA_RELAY_OWNER_TOKEN=development-only-change-me pnpm dev:relay:self-hosted
```

Run the CLI:

```bash
pnpm dev:cli -- providers
pnpm dev:cli -- doctor
pnpm dev:cli -- quota --format json --pretty
```

Run the public website:

```bash
pnpm dev:web
```

`quotacli quota` collects read-only ambient Codex, Claude Code, and Grok sessions into a versioned
collection report. Credentials never leave the local machine and are never printed.

## Status

This repository contains the architecture foundation plus local provider quota collection for Codex,
Claude Code, and Grok. Protocol validation, D1/SQLite storage, Relay discovery, local
provider-session discovery, the initial public website, and the Swift wire models are implemented.
Device pairing/authentication, realtime routing, and production UI remain subsequent milestones.

## License

Quota is released under the [MIT License](LICENSE).
