# QuotaBar

QuotaBar is the native macOS 14+ menu-bar UI. It ships as one app containing the SwiftUI executable
and a private Rust child at `Contents/Helpers/quota-service`.

## Runtime boundary

QuotaBar launches the fixed signed service path and keeps a persistent stdin/stdout NDJSON IPC v1
connection. The helper emits `{"type":"event","event":"ready","ipc_version":1}` once it has opened
its local state; QuotaBar sends nothing before that and shows its loading state, restarts one start
that stays silent for a minute, and reports the service unavailable after a second. Requests have no
deadline. While one is outstanding QuotaBar pings every five seconds, and a helper that misses two
consecutive pings is terminated, killed if it will not exit, and replaced on the next request. If
the helper cannot initialize its owner-only state, it stays on the IPC boundary and returns only a
fixed, allowlisted error/recovery pair. It never resolves an executable from `PATH`, invokes a
shell, reads provider/service files, receives account/provider tokens, or contacts Relay directly.
Requests and responses are bounded to 1 MiB and use typed `snake_case` models; revisioned events
tell Swift when to reload state.

The Rust service returns persisted component state immediately, then performs startup collection in
the background. It owns the five-minute schedule, providers, Usage, pricing, OAuth/account sync,
its owner-only identity store and disposable cache, the hours it still owes an Account, and the
two-way merge of a subscription Relay resolved against this Mac's own reading.
When it has to rebuild that cache, `get_state.cache.rebuilding` says so and Overview shows one
notice until the next complete Usage scan. QuotaBar owns presentation, provider visibility
and ordering preferences, native provider configuration fields, account actions, accessibility, and
Launch at Login. Shared remaining-quota, plan/account label, compact count, Usage cost, and compact
relative-age text come from [`packages/apple-shared`](../../packages/apple-shared), and the managed
wire types plus `ProviderID` from its `QuotaWire` module. Private IPC models, the Usage upload and
local-report types, app-only provider behavior, and session/helper logic stay in this app; QuotaBar
does not depend on QuotaRelay or QuotaAccount, because the local service owns Relay traffic here.
The service persists the Usage upload preference so it applies before
its startup refresh. Quitting the app closes stdin and stops the service and all synchronization.

For catalog browser-session providers, QuotaBar pins login and Cookie discovery to one supported
browser application. SweetCookieKit 0.5.2 enumerates that browser's profiles with logging disabled
and returns only exact-host/name allowlist candidates in memory. Swift sends one minimal Cookie
header at a time to Rust for validation/commit; it never calls provider APIs or persists the header.
Cursor prefers a signed-in Cursor.app session and uses the same allowlisted browser acquisition as
a fallback; Codex, Claude, Grok, and Kimi reuse that browser path when their official credentials
are missing or rejected. QuotaBar 0.0.13 uploads its quota and Usage through managed-data v3;
released v2 clients remain isolated from Cursor. Browser cookies stay local.

Each background refresh precomputes Today, 7 Days, 30 Days, and All for This Mac and, when enabled,
the signed-in Account. The four values are persisted and returned by `get_state`; Swift only selects
among them and never slices totals or infers client/provider/model ownership.

Packaged builds embed Sparkle 2. Support's **Check for Updates** action, and Sparkle's daily
schedule, read the GitHub Releases appcast. Local `swift run` binaries are not packaged and do not
check for updates.

Settings' **Support** page is backed by the private `diagnose` IPC operation and renders the same
bounded, redacted report Linux `quotacli doctor` prints. The service evaluates the four Quota/Usage
surfaces and the sources behind them and writes one sentence per row; Swift strictly decodes and
renders it, and never maps a code to copy of its own. **Show in Overview** remains
presentation-only and never requests local collection. Account provider data remains healthy without
a matching local login, while an explicitly saved local provider setup is a required source. Recheck
requests the real single-flight refresh and waits for a newer evaluation; if the refresh is still
running after the UI wait, the last completed report stays visible. **Copy report** puts the whole
report on the pasteboard, including the recent work the page does not list. **Reset local data**
asks first, then deletes this Mac's cache — collected quota and Usage history — and refreshes; the
session, the upload queue, and saved browser sessions live in a different file and are untouched.
Raw paths, filenames, model lists, prompts, completions, session or device identifiers, credentials,
tokens, raw responses, and parser excerpts never appear in the copied report.

The recent work in that report comes from the service's seven-day, 5,000-row structured attempt
journal, capped at 100 entries. Account Devices show their platform, when each was last seen, and
when its newest reading was taken, labelled Active, Idle, or Not reporting. No Device asserts
anything about another, and QuotaBar cannot alter another Device or request credentials for it.

Provider API keys entered in Settings go directly over child stdin. Swift does not put them in argv,
UserDefaults, logs, or response models; subsequent state exposes only a masked tip.

The detailed system boundary is in [`docs/architecture.md`](../../docs/architecture.md), security
requirements are in [`docs/security.md`](../../docs/security.md), and UI behavior is canonical in
[`DESIGN.md`](DESIGN.md).

## Development

From the repository root:

```bash
swift test --package-path apps/menubar
cargo test --locked --package quota-menubar-helper
pnpm build:menubar:app
pnpm test:menubar:helper
open dist/menubar/QuotaBar.app
```

`swift run` does not assemble an app bundle and therefore does not provide the private service at its
production path. Use the packaging script for live integration. It builds arm64 Rust and Swift
binaries, copies resources, installs the service, and applies local ad-hoc signatures. The release
workflow replaces them with Developer ID signatures before notarization.
`pnpm test:menubar:helper` runs the packaged helper through the Swift IPC tests with an isolated
`HOME`, `XDG_CONFIG_HOME`, and provider data roots; it does not read the invoking user's local state.

## Visual QA

Build the deterministic visual app with `pnpm build:menubar:visual`. It accepts:

```text
--data-source fixture|live
--fixture loading|content|cached-refresh-error|empty|unavailable|cache-rebuilding
--route overview|settings|agents|provider-codex|provider-openrouter|provider-cursor|devices|usage|support
--appearance system|light|dark
--text-size standard|extra-large|accessibility
```

Fixture mode starts no service and contains synthetic account, device, quota, cost, and coverage
data. Live mode uses the packaged service through the production IPC boundary. Generated `.build/`,
Rust `target/`, packaged apps, databases, and local preferences are development state and must not be
committed.
