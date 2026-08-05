# QuotaCLI

QuotaCLI is the local provider collector and remote Relay agent. One TypeScript entry point produces
a Node ESM npm package and a standalone Bun executable.

Provider credentials are read locally and never sent to QuotaRelay. Supported collectors: Codex,
Claude Code, Grok (ambient sessions), and OpenRouter (API key credits + key limit via
`quotacli config` or `OPENROUTER_API_KEY`). Relay mode sends only validated, normalized quota
snapshots from `@gotry-io/quota-protocol`.

```bash
pnpm --filter @gotry-io/quotacli dev -- status
pnpm --filter @gotry-io/quotacli dev -- quota --format json --pretty
pnpm --filter @gotry-io/quotacli dev -- relay --help
pnpm --filter @gotry-io/quotacli build
```

## Commands

```text
quotacli version
quotacli status
quotacli quota [--provider codex|claude|grok|openrouter|all] [--format text|json] [--pretty]
quotacli relay pair [--relay <url>]
quotacli relay push
quotacli relay unpair
quotacli relay --help
quotacli config set <provider> --api-key-stdin [--base-url <https-url>]
quotacli config get <provider>
quotacli config unset <provider>
quotacli config list
quotacli help
```

`quota` defaults:

- `--provider all`
- `--format text` when attached to a terminal
- `--format json` otherwise

Exit codes for `quota`:

- `0`: every requested provider returned at least one fresh snapshot
- `1`: collection completed with one or more provider failures
- `2`: invalid CLI arguments

Relay commands return `0` on complete success, `1` for pairing, push, credential-store, or partial
provider-collection outcomes, and `2` for invalid commands or arguments. `status` returns `0` only
when at least one local provider credential source is available, launchd inspection succeeds, and
macOS background state matches pairing (`loaded` when paired, `stopped` when unpaired). Otherwise
it returns `1`. Missing providers do not fail `status` by themselves if another provider is present.

JSON output is one versioned `QuotaCollectionReport`. Provider failures stay inside the report.
QuotaCLI never prints credentials, authorization headers, cookies, raw JWTs, or unredacted response
bodies.

## Distribution artifacts

`build:npm` creates the Node-based `dist/npm/quotacli.js` intended for publication as
`@gotry-io/quotacli`. `build:standalone` creates `dist/standalone/quotacli` for the QuotaBar app
bundle and direct release downloads. The npm package installs the same `quotacli` command and does
not require Bun at runtime. A `cli-v*` Git tag publishes the package from `release-cli.yml` through
npm Trusted Publishing; the release workflow stores no long-lived npm credential. Stable tags
publish to the `latest` dist-tag and update the Homebrew Formula `gotry-io/tap/quotacli` (installs
the npm tarball via Node). Prerelease tags such as `cli-v0.0.2-beta.1` publish to `beta` only
(`npm install -g @gotry-io/quotacli@beta`); they do not update Homebrew. QuotaBar uses separate
`menubar-v*` tags and is not published by this workflow.

Local version bump (commits `apps/cli/package.json` by default):

```bash
pnpm version:bump:cli patch    # also: minor | major | 0.1.0
git tag -a "cli-v$(node -p "require('./apps/cli/package.json').version")" -m "QuotaCLI release"
git push origin "cli-v$(node -p "require('./apps/cli/package.json').version")"
```

### Install

```bash
# Homebrew (stable; requires Node via brew)
brew install gotry-io/tap/quotacli

# npm (stable)
npm install -g @gotry-io/quotacli

# npm (beta)
npm install -g @gotry-io/quotacli@beta
```

### Provider config (API keys)

API-key providers (catalog `config.kind: "api_key"`, currently OpenRouter) use a shared owner-only
file (`$XDG_CONFIG_HOME/quotacli/providers.json` or `~/.config/quotacli/providers.json`). Collection
prefers that file over environment variables. Do not pass secrets on argv.

```bash
printf '%s' "$OPENROUTER_API_KEY" | quotacli config set openrouter --api-key-stdin
quotacli config get openrouter    # masked tip only
quotacli config list
quotacli config unset openrouter
quotacli quota --provider openrouter
```

QuotaBar Settings sections for the same providers write the same file.

## Relay pairing

Pair a machine with the managed Relay origin or a selected self-hosted Relay:

```text
quotacli relay pair                         # defaults to https://quota.gotry.io
quotacli relay pair --relay https://relay.example.com
quotacli relay push
quotacli relay unpair
quotacli status
```

`pair` discovers and validates Relay capabilities, displays a Relay-generated user code for
approval in QuotaBar, and stores the issued Relay-bound device credential. It does not accept a
manually created token. After the credential is saved, `pair` performs one foreground collection
and upload so the owner can see the device leave Waiting promptly. On macOS it then installs the
background LaunchAgent, which continues `relay push` every five minutes. QuotaBar registers an
isolated anonymous owner capability for the selected Relay URL (managed or self-hosted) without a
user account or bootstrap token, then approves the displayed pairing code.

`unpair` stops and removes the macOS background service, verifies the saved Relay instance, revokes
the current device with its device credential, and then deletes the local credential. If discovery
or revocation fails, the local credential is retained so the command can be retried. The Relay
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

On macOS, after the foreground first upload, `pair` installs and loads the user LaunchAgent
`io.gotry.quotacli.relay`. The agent runs the same executable's `relay push` command at load
(login/reboot) and every five minutes. The local device credential is stored at
`$XDG_CONFIG_HOME/quotacli/device.json` or `~/.config/quotacli/device.json`.
`status` reports provider readiness, pairing, Relay, device, sequence, and loaded/stopped background
state without displaying the device token. `unpair` removes the LaunchAgent together with the remote
device and local credential.

The LaunchAgent preserves only the allowlisted path and provider-location settings needed for the
same collection behavior outside an interactive shell. It does not contain Relay or provider
credentials. Background push is supported only on macOS; one-shot `pair`, `push`, and `unpair`
remain cross-platform. Outside macOS, `pair` saves the credential and tells the operator to run
`relay push` manually when needed.
