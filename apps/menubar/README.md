# QuotaBar

QuotaBar is the native macOS 14+ menu-bar UI. It ships as one app containing the SwiftUI executable
and a private Rust child at `Contents/Helpers/quota-service`.

## Runtime boundary

QuotaBar launches the fixed signed service path and keeps a persistent stdin/stdout NDJSON IPC v1
connection. Every request has a fixed fifteen-second deadline; a timed-out request closes the child and
the next request starts a clean helper. If the helper cannot initialize its owner-only state, it
stays on the IPC boundary and returns only a fixed, allowlisted error/recovery pair. It never
resolves an executable from `PATH`, invokes a shell, reads provider/service files, receives
account/provider tokens, or contacts Relay directly. Requests and responses are bounded to 1 MiB and
use typed `snake_case` models; revisioned events tell Swift when to reload state.

The Rust service returns persisted component state immediately, then performs startup collection in
the background. It owns the five-minute schedule, providers, Usage, pricing, OAuth/account sync,
SQLite, outbox, and local/account observation merge. QuotaBar owns presentation, provider visibility
and ordering preferences, native provider configuration fields, account actions, accessibility, and
Launch at Login. The service persists the Usage upload preference so it applies before its startup
refresh. Quitting the app closes stdin and stops the service and all synchronization.

For catalog browser-session providers, QuotaBar pins login and Cookie discovery to one supported
browser application. SweetCookieKit 0.5.2 enumerates that browser's profiles with logging disabled
and returns only exact-host/name allowlist candidates in memory. Swift sends one minimal Cookie
header at a time to Rust for validation/commit; it never calls provider APIs or persists the header.
Cursor is the first adapter. QuotaBar 0.0.13 uploads its quota and Usage through managed-data v3;
released v2 clients remain isolated from Cursor.

Each background refresh precomputes Today, 7 Days, 30 Days, and All for This Mac and, when enabled,
the signed-in Account. The four values are persisted and returned by `get_state`; Swift only selects
among them and never slices totals or infers client/provider/model ownership.

Packaged builds embed Sparkle 2. Support's **Check for Updates** action, and Sparkle's daily
schedule, read the GitHub Releases appcast. Local `swift run` binaries are not packaged and do not
check for updates.

Settings includes a **Diagnostics** action backed by the private `diagnose` IPC operation. It copies
the same bounded, redacted report consumed by Linux `quotacli doctor`, covering provider/quota
collection, Usage, pricing, account state, and synchronization. Swift strictly decodes the fixed
report shape and only renders safe status, counters, and recovery messages; it never reads SQLite or
source logs. Raw paths, filenames, model lists, prompts, completions, session identifiers, device
IDs, credentials, and tokens are excluded.

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
--fixture loading|content|cached-refresh-error|empty|unavailable
--route overview|settings|agents|provider-codex|provider-openrouter|devices|usage|support|diagnostics
--appearance system|light|dark
--text-size standard|extra-large|accessibility
```

Fixture mode starts no service and contains synthetic account, device, quota, cost, and coverage
data. Live mode uses the packaged service through the production IPC boundary. Generated `.build/`,
Rust `target/`, packaged apps, databases, and local preferences are development state and must not be
committed.
