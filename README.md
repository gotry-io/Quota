# Quota

Quota is the monorepo behind [quota.gotry.io](https://quota.gotry.io), monitoring coding-agent
subscription quotas.

- **QuotaBar** — native macOS menu bar app for local and remote quotas.
- **QuotaCLI** — standalone local collector and installable Relay agent.
- **QuotaRelay** — persistent device registry and normalized snapshot relay.

The initial providers are Codex, Claude Code, and Grok.

## Architecture

QuotaCLI collects provider quota locally and emits normalized snapshots; provider credentials never
cross its process boundary. QuotaBar consumes local results directly and may read remote snapshots
through a persistent QuotaRelay.

The canonical system description is in [architecture](docs/architecture.md). See the
[security baseline](docs/security.md), [provider strategies](docs/provider-collection.md),
[persistent storage decision](docs/decisions/0001-persistent-relay-storage.md),
[device pairing decision](docs/decisions/0002-relay-device-code-pairing.md),
[anonymous controller decision](docs/decisions/0004-anonymous-relay-controllers.md), and
[website design system](apps/web/DESIGN.md) and
[QuotaBar design system](apps/menubar/DESIGN.md) for their respective concerns.

## Repository layout

```text
apps/web/                Quota public website and static Cloudflare assets
apps/menubar/            QuotaBar Swift 6.2 / SwiftUI app
apps/cli/                QuotaCLI Node package and Bun standalone executable
apps/relay/              Hono Relay for Workers+D1 and Bun+SQLite
packages/protocol/       Runtime schemas and language-neutral JSON Schemas
packages/quota-model/    Runtime-neutral quota calculations
packages/provider/       Node/Bun provider collection for QuotaCLI
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
pnpm test:relay:e2e
```

Run the self-hosted Relay with persistent SQLite storage:

```bash
export QUOTA_RELAY_CONTROLLER_TOKEN="$(openssl rand -hex 32)"
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
  `quotacli` command for developers and relay machines.
- The same CLI source also produces a Bun standalone executable for the QuotaBar helper and release
  artifacts.

QuotaBar's arm64 release channel is automated from a `v*` tag: GitHub Actions signs and notarizes
the app, publishes its ZIP, and pushes the matching Cask to `gotry-io/homebrew-tap`. The same tag
publishes QuotaCLI independently through npm Trusted Publishing, without a long-lived npm token.

## Status

This repository implements local provider collection for Codex, Claude Code, and Grok, normalized
protocol validation, persistent D1/SQLite Relay storage, Relay discovery, and the initial public
website. QuotaBar ships its bundled helper and now resolves local and remote observations into one
stable Overview without accumulating conflicting quota values. One Relay state model is shared by
five-minute app-lifecycle polling and the typed Settings stack for Relay profiles, pairing decisions,
device listing, and revocation. Controller capabilities remain in Keychain.

The macOS Relay acceptance test exercises a real LaunchServices-started QuotaBar and QuotaCLI
against isolated managed and self-hosted Relay runtimes. It covers anonymous managed enrollment,
controller persistence, device pairing, a non-empty report, Remote Overview rendering, device
revocation and rejection, remote self-unpairing, restart restoration, and credential cleanup.

QuotaRelay implements its protocol-validated `/api/v1` server core for device-code pairing, scoped
Bearer authentication, snapshot upload and reads, device management, and persistent rate limiting.
The managed runtime issues anonymous controller capabilities without a user account; the
self-hosted runtime bootstraps one controller from its environment. Controllers can revoke devices
or delete their managed data, devices can revoke themselves, and devices inactive for 30 days are
automatically revoked. Abandoned managed controllers and expired pairing state are reclaimed by
scheduled maintenance, while self-hosted controllers remain permanent. QuotaCLI implements Relay pairing, one-shot `relay push`, remote unpairing, and a macOS LaunchAgent
that runs push at load and every five minutes after pairing. Top-level `status` summarizes local
provider readiness and Relay background state. QuotaCLI 0.1.0 is published on npm and later tags
publish through OIDC.

The deterministic Visual App captures its own window without Screen Recording permission, and its
automated acceptance harness validates twelve Overview and Settings scenes across appearance and
text-size variants. Background-service support outside macOS and the first published Homebrew
artifact remain incomplete. Realtime delivery is optional and not part of v1.

## License

Quota is released under the [MIT License](LICENSE).
