# Quota

Quota is the monorepo behind [quota.gotry.io](https://quota.gotry.io), monitoring coding-agent
subscription quotas.

- **QuotaBar** — native macOS menu bar app for local and remote quotas.
- **QuotaCLI** — standalone local collector and installable Relay agent.
- **QuotaRelay** — persistent device registry and normalized snapshot relay.

The initial providers are Codex, Claude Code, Grok, and OpenRouter.

## Architecture

QuotaCLI collects provider quota locally and emits normalized snapshots; provider credentials never
cross its process boundary. QuotaBar consumes local results directly and may read remote snapshots
through a persistent QuotaRelay.

The canonical system description is in [architecture](docs/architecture.md). See the
[security baseline](docs/security.md), [provider strategies](docs/provider-collection.md),
[persistent storage decision](docs/decisions/0001-persistent-relay-storage.md),
[device pairing decision](docs/decisions/0002-relay-device-code-pairing.md),
[anonymous owner decision](docs/decisions/0004-anonymous-relay-owners.md),
[URL-only Relay enrollment](docs/decisions/0005-url-only-relay-enrollment.md), and
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

`quotacli quota` collects read-only ambient Codex, Claude Code, and Grok sessions plus OpenRouter API
key credits into a versioned collection report. Credentials never leave the local machine and are
never printed.

## Distribution targets

- QuotaBar is intended for distribution as a Homebrew Cask from `gotry-io/homebrew-tap`. Its signed
  app bundle
  includes a private QuotaCLI helper, so desktop users do not install the CLI separately.
- QuotaCLI is published as `@gotry-io/quotacli` on npm and as a Homebrew Formula
  (`gotry-io/tap/quotacli`) that installs that npm package. Developers and Relay machines can use
  either channel for the `quotacli` command.
- The same CLI source also produces a Bun standalone executable for the QuotaBar helper and release
  artifacts.

QuotaCLI and QuotaBar use **independent semver and release tags**. A `cli-v*` tag runs only
`release-cli.yml` (npm Trusted Publishing; stable also updates Homebrew Formula
`gotry-io/tap/quotacli`). A `menubar-v*` tag runs only `release-menubar.yml` (sign, notarize, GitHub
Release ZIP; stable also updates the Cask). QuotaBar still ships a **bundled** QuotaCLI helper built
from the same commit's `apps/cli` sources; the helper reports the CLI package version, which may
differ from the App marketing version. **Prerelease** tags use a hyphen suffix (for example
`cli-v0.0.2-beta.1`, `menubar-v0.0.2-beta.1`): CLI goes to npm `beta`, App becomes a GitHub
prerelease, and Homebrew is not updated.

Managed Relay and the public website deploy together from `main` through
`.github/workflows/deploy-cloudflare.yml`. The job applies remote D1 migrations, builds
`apps/web`, and runs `wrangler deploy` so `quota.gotry.io` serves both the API Worker and website
Static Assets. Path filters cover `apps/relay`, `apps/web`, `packages/protocol`, and
`packages/relay-core`. Manual `workflow_dispatch` is available. Requires repository secrets
`CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`, and uses the `production` GitHub Environment.

Pull requests run AI review through `.github/workflows/pr-agent.yml` (PR-Agent over a
LiteLLM-compatible OpenAI API). Configure secret `LITELLM_API_KEY` and Actions variables
`LITELLM_API_BASE`, `LITELLM_MODEL`, and `LITELLM_FALLBACK_MODELS`. On each non-draft PR,
PR-Agent auto-runs `/describe` and `/review`; comment `/improve` or `/ask …` for on-demand tools.

## Status

This repository implements local provider collection for Codex, Claude Code, Grok, and OpenRouter,
normalized protocol validation, persistent D1/SQLite Relay storage, Relay discovery, and the initial
public website. QuotaBar ships its bundled helper and resolves local and remote observations into one
stable Overview without accumulating conflicting quota values. One Relay state model is shared by
five-minute app-lifecycle polling and the typed Settings stack for **Remote Devices** and **Pair
Device**. A Relay is only an endpoint URL; each QuotaBar holds a hidden owner capability in Keychain
and sees only the devices it paired.

The macOS Relay acceptance test exercises a real LaunchServices-started QuotaBar and QuotaCLI
against isolated managed and self-hosted Relay runtimes. It covers anonymous owner enrollment on both
runtimes, Keychain persistence, device pairing, a non-empty report, Remote Overview rendering, device
revocation and rejection, remote self-unpairing, restart restoration, and credential cleanup.

QuotaRelay implements its protocol-validated `/api/v1` server core for device-code pairing, scoped
Bearer authentication, snapshot upload and reads, device management, and persistent rate limiting.
Both managed and self-hosted runtimes issue the same anonymous, isolated, expiring owner capabilities
without user accounts or a bootstrap token. Owners can revoke their own devices or delete their
group; devices can revoke themselves; devices and owner groups inactive for 30 days are reclaimed by
scheduled maintenance. QuotaCLI implements Relay pairing with one foreground upload after join,
one-shot `relay push`, remote unpairing, and a macOS LaunchAgent that continues push every five
minutes after pairing. Top-level `status` summarizes local provider readiness and Relay background
state.

The first public releases used bare `v*` tags that shipped CLI and QuotaBar together. **Current**
releases use product-prefixed tags so either product can ship alone (for example a CLI-only bugfix).
Managed Relay plus website deploy remains separate: pushes to `main` that touch Relay/web/protocol
inputs run `deploy-cloudflare.yml`.

### Version channels

| Tag example | Product | Channel | Artifacts |
| --- | --- | --- | --- |
| `cli-v0.0.4` | QuotaCLI | stable | npm `@latest`, Homebrew Formula `quotacli` |
| `cli-v0.0.4-beta.1` | QuotaCLI | beta | npm `@beta` only |
| `menubar-v0.0.3` | QuotaBar | stable | GitHub Release ZIP, Homebrew Cask `quotabar` |
| `menubar-v0.0.3-beta.1` | QuotaBar | beta | GitHub prerelease ZIP only |

Rules:

- Use semver per product. Prerelease **must** include a hyphen suffix (`0.0.4-beta.1`, not
  `0.0.4beta1`). Prefer `beta.N` for public validation builds.
- CLI version lives in `apps/cli/package.json`. QuotaBar marketing version lives in
  `apps/menubar/Support/Info.plist` (`CFBundleShortVersionString`). Internal packages and managed
  Relay/web do **not** drive client tags.
- Bump (same idea as `npm version`):

  ```bash
  pnpm version:bump:cli patch          # or minor | major | 0.1.0
  pnpm version:bump:menubar patch
  pnpm version:bump:cli patch --no-commit
  ```

  Default commits only the touched product file. Then publish:

  ```bash
  git tag -a cli-v0.0.4 -m "QuotaCLI 0.0.4" && git push origin cli-v0.0.4
  git tag -a menubar-v0.0.3 -m "QuotaBar 0.0.3" && git push origin menubar-v0.0.3
  ```

- A CLI-only tag does **not** update QuotaBar's bundled helper. Ship a `menubar-v*` release when
  menu-bar local collection must pick up the fix (Release notes should mention the helper version).
- Install stable CLI with Homebrew (`brew install gotry-io/tap/quotacli`) or
  `npm install -g @gotry-io/quotacli`.
- Install beta CLI with `npm install -g @gotry-io/quotacli@beta` or pin
  `@gotry-io/quotacli@0.0.4-beta.1` (no Homebrew Formula for beta).
- Install stable QuotaBar with Homebrew Cask or the latest stable GitHub Release for `menubar-v*`.
- Install beta QuotaBar from the GitHub prerelease ZIP only; do not `brew upgrade` for beta.

The deterministic Visual App captures its own window without Screen Recording permission, and its
automated acceptance harness validates Overview and Settings scenes across appearance and text-size
variants. Background-service support outside macOS remains incomplete. Realtime delivery is optional
and not part of v1.

## License

Quota is released under the [MIT License](LICENSE).
