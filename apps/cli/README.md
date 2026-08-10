# QuotaCLI

QuotaCLI is Quota's local provider collector and sole native account/sync client. One strict ESM
entry point produces the Node npm package for headless non-macOS machines and QuotaBar's private Bun
helper on macOS.

Provider credentials and raw agent logs remain local. Account sync sends only protocol-v2 quota
observations, complete UTC-hour Usage facts, and coverage/control metadata to the fixed managed
origin `https://quota.gotry.io`.

## Commands

```text
quotacli version
quotacli status [--provider <id>|all] [--format text|json] [--pretty]
quotacli doctor
quotacli login [--device-auth] [--format text|json] [--pretty]
quotacli logout [--format text|json] [--pretty]
quotacli auth status [--format text|json] [--pretty]
quotacli sync [--format json] [--pretty]
quotacli account summary [--from YYYY-MM-DD] [--to YYYY-MM-DD]
  [--device-id <id>] [--cost-mode calculate|auto|reported] [--pretty]
quotacli config set <provider> [--base-url <url>]
quotacli config get <provider>
quotacli config unset <provider>
quotacli config list
```

`status` is local-only. It defaults to providers whose credential sources are present, text output
on a terminal, and JSON when redirected. Progress uses stderr so stdout stays machine-readable.

`login` opens GitHub-backed browser authorization with a loopback PKCE callback. `--device-auth`
uses the OAuth Device Authorization Grant for headless machines. QuotaCLI receives Quota account and
current-device sessions, never a GitHub token.

`sync` always returns local quota and an all-history local Codex, Claude Code, Grok, OpenCode, and Pi
Usage report, including while signed out. While signed in it also obtains authoritative Device
generation and independent
quota/Usage sequences, refreshes the canonical pricing catalog while preserving the last valid
cache, uploads the quota snapshot, drains a bounded immutable Usage outbox, and returns the account
summary. Complete scans replace remote UTC-hour ranges; partial scans remain local. Logout disables
upload locally before revoking sessions and does not delete the remote Device or data.

`account summary` is JSON and can filter the Usage date range, Device, and cost mode. Calculated cost
is API-equivalent catalog pricing, not subscription spend or an invoice. With no date filter it
returns all retained Account Usage. Unknown prices remain unpriced instead of becoming zero.

`doctor` reports provider and account readiness without collection or upload. Non-macOS recurring
sync requires an external scheduler. QuotaBar invokes its bundled helper every five minutes while the
app runs.

## Local state

API-key provider configuration lives in
`$XDG_CONFIG_HOME/quotacli/providers.json` or `~/.config/quotacli/providers.json`. Do not pass secrets
on argv; `config get/list` return a masked tip only.

Account state uses the same user configuration root:

```text
installation.json
session.json
usage-cache.json
usage-outbox.json
pricing-catalog.json
state.lock
```

These artifacts are outside the npm/app installation directory, explicitly versioned, owner-only,
symlink-resistant, and atomically replaced under one cross-process lock. QuotaBar never reads them.
Newer schema versions fail closed until QuotaCLI is upgraded.

The durable outbox never contains raw paths, source cursors, prompts, completions, session IDs, or
conversation IDs. A retry reuses its submission ID/generation/sequence. Web Device deletion advances
the server generation and watermark, making an old offline outbox terminal.

## Development and distribution

```bash
pnpm --filter @gotry-io/quotacli dev -- doctor
pnpm --filter @gotry-io/quotacli dev -- status --format json --pretty
pnpm --filter @gotry-io/quotacli check
pnpm --filter @gotry-io/quotacli test
pnpm --filter @gotry-io/quotacli build
```

`build:npm` creates the Node `dist/npm/quotacli.js`. `build:menubar-helper` creates the private
QuotaBar helper and is not a standalone macOS artifact. The npm runtime does not require Bun or a
native addon.

Install QuotaBar and its bundled command on macOS with
`brew install --cask gotry-io/tap/quotabar`. Install the headless CLI elsewhere with
`npm install -g @gotry-io/quotacli`.

`cli-v*` tags publish the npm package through Trusted Publishing; QuotaBar has independent
`menubar-v*` releases. See the root [`README.md`](../../README.md) for versioning and deployment
boundaries and [`docs/security.md`](../../docs/security.md) for credential rules.
