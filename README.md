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
apps/cli/                QuotaCLI Node package and Bun standalone executable
apps/relay/              Hono Relay for Workers+D1 and Bun+SQLite
packages/protocol/       Runtime schemas and language-neutral JSON Schemas
packages/quota-model/    Runtime-neutral quota calculations
packages/provider-core/  Provider interfaces without Node dependencies
packages/provider-node/  Filesystem, process, and credential discovery for QuotaCLI
packages/relay-core/     Persistent Relay state contract
deploy/                  Self-hosted container configuration
docs/                    Architecture, security, and decision records
```

All TypeScript packages use the `@gotry-io/*` namespace. Wire JSON remains `snake_case`; Swift models
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
pnpm dev:relay:self-hosted
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

## Distribution targets

- QuotaBar is distributed as a Homebrew Cask from `gotry-io/homebrew-tap`. Its signed app bundle
  includes a private QuotaCLI helper, so desktop users do not install the CLI separately.
- QuotaCLI is published as `@gotry-io/quotacli`; `npm install -g @gotry-io/quotacli` installs the
  `quotacli` command for developers and edge machines.
- The same CLI source also produces a Bun standalone executable for the QuotaBar helper and release
  artifacts.

QuotaBar's arm64 release channel is automated from a `v*` tag: GitHub Actions signs and notarizes
the app, publishes its ZIP, and pushes the matching Cask to `gotry-io/homebrew-tap`. The same tag
publishes QuotaCLI independently through npm Trusted Publishing, without a long-lived npm token.

## Status

This repository contains the architecture foundation plus local provider quota collection for Codex,
Claude Code, and Grok. Protocol validation, D1/SQLite storage, Relay discovery, local
provider-session discovery, the initial public website, and the Swift wire models are implemented.
QuotaBar now includes its first local quota panel, bundled-helper integration, and arm64 release
automation. QuotaCLI 0.1.0 is published on npm and later tags publish through OIDC. Authenticated
Relay APIs, device pairing, the first published Homebrew artifact, remote-device UI, and production
settings remain subsequent milestones. Realtime delivery is optional and not part of v1.

## License

Quota is released under the [MIT License](LICENSE).
