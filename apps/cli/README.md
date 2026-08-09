# QuotaCLI

QuotaCLI is the local provider collector and remote Relay agent. One TypeScript entry point produces
a Node ESM npm package for non-macOS headless machines and QuotaBar's private Bun helper on macOS.

Provider credentials are read locally and never sent to QuotaRelay. Supported collectors: Codex,
Claude Code, Grok (ambient sessions), and API-key collectors (OpenRouter, DeepSeek, Kimi Code,
LiteLLM via `quotacli config` / env). Relay mode sends only validated, normalized quota snapshots
from `@gotry-io/quota-protocol`.

```bash
pnpm --filter @gotry-io/quotacli dev -- doctor
pnpm --filter @gotry-io/quotacli dev -- status --format json --pretty
pnpm --filter @gotry-io/quotacli dev -- relay --help
pnpm --filter @gotry-io/quotacli build
```

## Commands

```text
quotacli version
quotacli status [--provider <id>|all] [--format text|json] [--pretty]
quotacli doctor
quotacli relay pair [--relay <url>]
quotacli relay push
quotacli relay unpair
quotacli relay --help
quotacli config set <provider> [--base-url <url>]
quotacli config get <provider>
quotacli config unset <provider>
quotacli config list
quotacli help
```

`status` defaults:

- collect providers whose local credential source is present; use `--provider all` to include every
  catalog provider
- `--format text` when attached to a terminal
- `--format json` otherwise

Interactive text mode shows discovery and collection progress on stderr, then renders each provider
as a clearly separated card with remaining-quota meters. JSON and redirected output contain no
progress control sequences; `NO_COLOR` disables ANSI color.

Exit codes for `status`:

- `0`: every requested provider returned at least one fresh snapshot
- `1`: no configured provider, or collection completed with a provider/session failure
- `2`: invalid CLI arguments

Relay commands return `0` on complete success, `1` for pairing, push, credential-store, or partial
provider-collection outcomes, and `2` for invalid commands or arguments. `doctor` returns `0` when
at least one local provider credential source is available; it reports pairing and the platform's
recurring scheduling owner without inspecting a background service. Missing providers do not fail
`doctor` by themselves if another provider is present.

JSON output is one versioned `QuotaCollectionReport`. Provider failures stay inside the report.
QuotaCLI never prints credentials, authorization headers, cookies, raw JWTs, or unredacted response
bodies.

## Distribution artifacts

`build:npm` creates the Node-based `dist/npm/quotacli.js` intended for publication as
`@gotry-io/quotacli`. `build:menubar-helper` creates `dist/menubar-helper/quotacli` only for the
signed QuotaBar app bundle; it is not a standalone macOS release artifact. The npm package does not
require Bun at runtime. A `cli-v*` Git tag publishes the package from `release-cli.yml` through npm
Trusted Publishing; the workflow stores no long-lived npm credential and does not update Homebrew.
Prerelease tags such as `cli-v0.0.2-beta.1` publish to `beta`. QuotaBar uses separate `menubar-v*`
tags and its Cask exposes the bundled helper as the macOS `quotacli` command.

Local version bump (commits `apps/cli/package.json` by default):

```bash
pnpm version:bump:cli patch    # also: minor | major | 0.1.0
git tag -a "cli-v$(node -p "require('./apps/cli/package.json').version")" -m "QuotaCLI release"
git push origin "cli-v$(node -p "require('./apps/cli/package.json').version")"
```

### Install

```bash
# macOS: installs QuotaBar and its signed bundled command
brew install --cask gotry-io/tap/quotabar

# Non-macOS npm (stable)
npm install -g @gotry-io/quotacli

# Non-macOS npm (beta)
npm install -g @gotry-io/quotacli@beta
```

### Provider config (API keys)

API-key providers (catalog `config.kind: "api_key"`) use a shared owner-only
file (`$XDG_CONFIG_HOME/quotacli/providers.json` or `~/.config/quotacli/providers.json`). Collection
prefers that file over environment variables. Do not pass secrets on argv.

```bash
quotacli config set deepseek
quotacli config get openrouter    # masked tip only
quotacli config list
quotacli config unset openrouter
quotacli status --provider openrouter
```

QuotaBar Settings sections for the same providers write the same file.

## Relay pairing

Pair a machine with the managed Relay origin or a selected self-hosted Relay:

```text
quotacli relay pair                         # defaults to https://quota.gotry.io
quotacli relay pair --relay https://relay.example.com
quotacli relay push
quotacli relay unpair
quotacli doctor
```

`pair` discovers and validates Relay capabilities, displays a Relay-generated user code for
approval in QuotaBar, and stores the issued Relay-bound device credential. It does not accept a
manually created token. After the credential is saved, `pair` performs one foreground collection
and upload so the owner can see the device leave Waiting promptly. QuotaBar registers an isolated
anonymous owner capability for the selected Relay URL (managed or self-hosted) without a user
account or bootstrap token, then approves the displayed pairing code.

If that first upload fails, the issued pairing is retained. On macOS the running QuotaBar app
retries through its bundled helper; elsewhere the operator retries explicitly with
`quotacli relay push`.

`unpair` verifies the saved Relay instance, revokes the current device with its device credential,
and then deletes the local credential. If discovery or revocation fails, the local credential is
retained so the command can be retried. The Relay
returns the same successful response when that exact device credential has already revoked itself;
an unknown or rejected credential is not treated as proof of revocation. Pairing and credential
ownership are defined in
[`ADR 0002`](../../docs/decisions/0002-relay-device-code-pairing.md); storage requirements are in the
[`security baseline`](../../docs/security.md).

`push` verifies the saved Relay instance through unauthenticated discovery, performs one local
all-provider collection, and uploads the normalized successful snapshots. An empty snapshot list is
sent when every provider fails so the Relay can record a device heartbeat without deleting retained
observations. The local sequence advances only after the Relay returns `204`. A partial collection
is uploaded but returns exit code `1` with an explicit notice.

## Recurring relay push

On macOS, QuotaBar owns recurring reporting. Its signed Login Item starts the menu-bar app, which
checks for the local Relay device credential once at app launch and every five minutes while the app
remains running, and invokes the bundled helper only while paired. Quitting QuotaBar pauses uploads;
there is no separate QuotaCLI LaunchAgent. Before a macOS pair, push, or unpair, the helper removes
the fixed `io.gotry.quotacli.relay` service left by earlier releases.
If that safe cleanup fails, the operation stops before Relay state changes and prints the fixed
service label and plist path for manual recovery; it never includes launchctl output or credentials.

The local device credential is stored at `$XDG_CONFIG_HOME/quotacli/device.json` or
`~/.config/quotacli/device.json`. `doctor` reports provider readiness, pairing, Relay, device,
sequence, and the platform scheduling owner without displaying the device token. Outside macOS,
recurring uploads require an external scheduler calling `quotacli relay push`.
