# Quota

Quota is the monorepo behind [quota.gotry.io](https://quota.gotry.io). It keeps coding-agent
subscription quota and privacy-preserving Usage together across a user's devices.

- **QuotaBar** — native macOS menu-bar account, quota, and Usage UI.
- **QuotaCLI** — local collector, account client, durable sync owner, and QuotaBar's bundled helper.
- **QuotaRelay** — managed account/device service on Cloudflare Workers and D1.
- **Quota Web** — public site, GitHub login, device authorization, and account dashboard.

Quota collection supports Codex, Claude Code, Grok, OpenRouter, DeepSeek, Kimi Code, and LiteLLM.
Local Usage analytics currently supports Codex and Claude Code logs. Provider credentials, prompts,
completions, raw events, local paths, and conversation identifiers never upload.

## Architecture

QuotaCLI collects provider quota and Usage locally. A signed-in installation uploads only normalized
quota observations and sparse hourly Usage facts to the fixed managed origin
`https://quota.gotry.io`. QuotaBar invokes its bundled QuotaCLI and renders typed results; it does not
read credentials or QuotaCLI state files. The website and QuotaBar read the same account summary.

GitHub is the only account identity provider; Better Auth owns the browser OAuth/session boundary.
Accounts directly own Devices; there is no anonymous owner, device pairing group, configurable Relay
URL, Relay discovery, self-hosted runtime, or SQLite adapter. See the canonical
[architecture](docs/architecture.md), [security baseline](docs/security.md),
[provider strategies](docs/provider-collection.md), [managed account decision](docs/decisions/0006-managed-account-device-usage.md),
and [persistent storage decision](docs/decisions/0001-persistent-relay-storage.md).

## Repository layout

```text
apps/web/                Public site and authenticated account UI
apps/menubar/            QuotaBar Swift 6.2 / SwiftUI app
apps/cli/                QuotaCLI Node package and bundled Bun executable source
apps/relay/              Managed Hono Worker and D1 adapters
packages/protocol/       Runtime schemas and language-neutral JSON Schemas
packages/quota-model/    Runtime-neutral quota, aggregation, and pricing calculations
packages/provider/       Local provider quota and Usage collectors
packages/relay-core/     Runtime-neutral account and Usage state contracts
docs/                    Architecture, security, provider, and decision records
```

TypeScript is strict ESM. Workspace packages use `@gotry-io/*`. Wire JSON is `snake_case` and the
single current protocol is v2; Swift wire models decode the same contracts.

## Development

Requirements: Node.js 24+, pnpm 10+, Bun 1.3+, and Swift 6.2+ on macOS.

```bash
pnpm install
pnpm format:check
pnpm check
pnpm test
pnpm build
```

Useful entry points:

```bash
pnpm dev:cli -- status --format json --pretty
pnpm dev:cli -- login
pnpm dev:cli -- sync --format json --pretty
pnpm dev:cli -- account summary --format json --pretty
pnpm dev:web
pnpm dev:relay
```

`quotacli status` is local-only. `quotacli sync` always returns local quota and a local 30-day Usage
report, then uploads quota and a bounded durable Usage outbox only when an account session is active. Non-macOS recurring sync needs
an external scheduler; QuotaBar schedules its bundled helper while the app is running.

Provider registration changes start in `packages/provider/src/catalog.ts`. After a catalog change,
run `pnpm generate:provider-catalog` so protocol provider IDs, JSON Schemas, and Swift `ProviderID`
remain aligned.

Managed Relay and the website deploy together from `main` through
`.github/workflows/deploy-cloudflare.yml`. The workflow applies D1 migrations, builds the site, and
deploys the Worker and Static Assets. Local `wrangler deploy --dry-run` is verification; do not apply
remote migrations or deploy manually without explicit authorization.

## Distribution

- QuotaBar is distributed as a signed/notarized macOS app and Homebrew Cask. Its bundle contains the
  compatible QuotaCLI helper, exposed by the Cask as `quotacli`.
- QuotaCLI is published as `@gotry-io/quotacli` for headless non-macOS installations. There is no
  separate macOS CLI artifact.
- `cli-vX.Y.Z` publishes only QuotaCLI; `menubar-vX.Y.Z` publishes only QuotaBar. A `-beta.N` suffix
  selects the prerelease channel. The two products have independent versions.

Version sources and bump commands:

```bash
pnpm version:bump:cli patch       # or minor | major | explicit semver
pnpm version:bump:menubar patch
```

CLI version lives in `apps/cli/package.json`; QuotaBar marketing version lives in
`apps/menubar/Support/Info.plist`. A QuotaBar release is required when its bundled helper must pick up
a CLI change.

## Current status

The repository implements Better Auth GitHub/Web sessions, protocol v2 native account/device
authentication, independent quota and Usage upload sequencing, D1 persistence, destructive deletion
watermarks, Codex/Claude Usage parsing, UTC-hour aggregation, effective-dated cost calculation,
QuotaCLI durable state/outbox, QuotaBar account UI, and the Web account dashboard. Unknown prices
remain visibly unpriced; partial scans do not replace remote facts.

Production GitHub OAuth and D1 deployment require the secrets documented by the managed Relay
configuration. The checked-in deployment workflow is the only authorized production path.

## License

Quota is MIT licensed with copyright attributed to `gotry-io contributors`.
