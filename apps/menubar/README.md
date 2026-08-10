# QuotaBar

QuotaBar is the native macOS menu-bar UI for Quota. It shows local provider quota, account devices,
and normalized Usage totals without implementing provider or account access itself.

## Runtime boundary

The app invokes the signed `Contents/Helpers/quotacli` executable at a fixed bundle path. It never
searches `PATH`, starts a shell, opens account HTTP connections, reads provider credentials, or
reads QuotaCLI account and Usage state files.

QuotaBar exposes four fixed helper operations:

```text
quotacli sync --format json
quotacli login --format json
quotacli logout --format json
quotacli account summary --format json
```

Sync, logout, and account-summary processes have a 60-second timeout and a 1 MiB stdout limit.
Interactive login has a 10-minute timeout and is cancellable from Settings. Helper stderr is
discarded. Timeout, cancellation, and output overflow terminate the child process before returning.

App launch starts one sync immediately and repeats it every five minutes while QuotaBar is running.
The footer refresh action also runs sync. There is no background daemon owned by QuotaBar.

The app decodes the QuotaCLI sync envelope strictly: its local quota and local Usage reports contain
protocol v2 data, with an optional account summary when signed in. A credential-free last-known sync
result is cached in QuotaBar's preferences so the panel can paint before the first current sync
completes. Account tokens, installation identity, provider credentials, and raw logs never enter
that cache.

## Menu panel

Overview presents remaining provider quota. When signed in, observations come from the account
summary and retain their device display names. When signed out, local collection remains available.
Quota percentages are never accumulated across sources; the freshest valid observation wins for a
global account identity.

Settings contains:

- Account: **Continue with GitHub**, the signed-in display label, cancellable login, and logout.
- Usage: an all-history local report available without an account; signed-in users can switch to
  Account.
- Account Data: read-only Devices.
- Local Providers: agent visibility, ordering, reporting provenance, and a copyable provider setup
  command. QuotaBar does not edit provider credential files.
- General: Launch at Login.
- About: version, website, and feedback links.

Usage defaults to the local report and shows its date range, token totals, requests, estimated cost,
cost basis, pricing catalog revision, unpriced row count, model breakdown, and coverage for Codex,
Claude Code, Grok, OpenCode, and Pi. Token and request counts use locale-aware decimal grouping for
small values and compact `k`/`M`/`B` suffixes for larger values. When an account summary is available,
the same page offers an Account source. QuotaBar formats the typed result; it does not carry a price
table or recalculate cost.

The visual and interaction specification is [`DESIGN.md`](DESIGN.md).

## Development

Run Swift commands from the repository root:

```bash
swift build --package-path apps/menubar
swift test --package-path apps/menubar
```

Build the distributable app, including the bundled arm64 helper:

```bash
pnpm build:menubar:app
```

The packaging script builds QuotaCLI and QuotaBar, installs the helper at the fixed bundle path,
signs nested code before the app, and verifies the complete signature. Local packages use ad-hoc
signing; the release workflow replaces it with Developer ID signing and notarization.

## Visual QA

Build the visual app:

```bash
pnpm build:menubar:visual
```

The visual binary accepts deterministic fixture arguments:

```text
--data-source fixture|live
--fixture loading|content|cached-refresh-error|empty|unavailable
--route overview|settings|agents|provider-codex|provider-openrouter|devices|usage
--appearance system|light|dark
--text-size standard|extra-large|accessibility
```

Fixture mode performs no helper work and contains synthetic account, device, quota, cost, and
coverage data. Live mode uses the packaged helper through the same production process boundary.

Generated `.build/`, packaged apps, and local preferences are development state and must not be
committed.
