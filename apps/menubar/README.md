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
two-way merge of a subscription Relay resolved against this Mac's own reading. Signing in is
Authorization Code with PKCE over a loopback callback and issues one session, which reads the
Account and writes this Mac's Device
([ADR 0027](../../docs/decisions/0027-one-token-per-client.md)).
When it has to rebuild that cache, `get_state.cache.rebuilding` says so and Overview shows one
notice until the next complete Usage scan. QuotaBar owns presentation, provider visibility
and ordering preferences, native provider configuration fields, account actions, accessibility, and
Launch at Login, and the Quota collection interval. Shared remaining-quota, plan/account label, compact count, Usage cost, and compact
relative-age text come from [`packages/apple-shared`](../../packages/apple-shared), and the managed
wire types plus `ProviderID` from its `QuotaWire` module. Private IPC models, the Usage upload and
local-report types, app-only provider behavior, and session/helper logic stay in this app; QuotaBar
does not depend on QuotaRelay or QuotaAccount, because the local service owns Relay traffic here.
The service persists the Usage upload preference so it applies before
its startup refresh. Quitting sends the service a `shutdown` and waits up to two seconds for it, so
a helper mid-write finishes before its pipe disappears and one that answers nothing costs the quit
two seconds and no more; closing stdin says the same thing either way.

QuotaBar reads a browser session for the five providers whose catalog row declares one — Cursor,
Codex, Claude, Grok, and Kimi — and always as the last rung, after every official credential that
provider has. **Browser Sign-in** is the control. Turning it on asks for a short consent that names
the cookie names and hosts, that accepted sessions stay in the local service database until the
scan is turned off, and that nothing is uploaded. Declining reads nothing. On confirmation QuotaBar stores the preference,
preflights installed browsers, and reads every granted store when this Mac has no usable official
credential. What is still missing opens the floating Browser Access window: one row per
installed browser with its gatekeeper and one action — Open Settings… for Safari Full Disk
Access (with a QuotaBar icon to drag into that list, and a Relaunch row afterwards, since that grant lands on the next launch), Allow… for a Chrome-family
Keychain item, Ready for everything else. The Agent page shows one summary row that opens it. SweetCookieKit 0.5.2 enumerates profiles with
logging disabled and returns only exact-host/name allowlist candidates in memory. Swift sends
Cookie headers to Rust for validation; it never calls provider APIs or persists the header. A
store macOS refuses ends that browser's attempt and is shown as its own state — with the grant to
change, not "no session found" — and reaches the Diagnostics page as the `browser_access_denied`
source. Cursor prefers a signed-in Cursor.app session and uses the browser session as its
fallback; Codex, Claude, Grok, and Kimi reach theirs only when their own credential is missing or
has been rejected. Browser cookies stay local.

Each background refresh precomputes Today, 7 Days, 30 Days, and All for This Mac and, when enabled,
the signed-in Account. The four values are persisted and returned by `get_state`; Swift only selects
among them and never slices totals or infers client/provider/model ownership.

Packaged builds embed Sparkle 2. Support's **Updates** action, and Sparkle's daily
schedule, read the GitHub Releases appcast. Local `swift run` binaries are not packaged and do not
check for updates.

Settings' **Support › Diagnostics** page is backed by the private `diagnose` IPC operation and
renders one bounded, redacted report; Support itself asks the service nothing. The service evaluates the four Quota/Usage
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
binaries, copies resources, installs the service, and applies local ad-hoc signatures. An ad-hoc
signature's designated requirement is the build's cdhash, so macOS treats every rebuild as a new
app and asks again for Full Disk Access, Removable Volumes, and the Chrome Safe Storage Keychain
item; set `QUOTABAR_CODESIGN_IDENTITY` to a self-signed code-signing certificate (Keychain Access ›
Certificate Assistant) to keep those grants across local builds. The release
workflow replaces them with Developer ID signatures before notarization.
`pnpm test:menubar:helper` runs the packaged helper through the Swift IPC tests with an isolated
`HOME`, `XDG_CONFIG_HOME`, and provider data roots; it does not read the invoking user's local state.

## Visual QA

Build the deterministic visual app with `pnpm build:menubar:visual`. It accepts:

```text
--data-source fixture|live
--fixture loading|content|cached-refresh-error|empty|unavailable|cache-rebuilding
--route overview|settings|account|agents|provider-codex|provider-openrouter|provider-cursor|provider-codex-source|provider-litellm-key|devices|usage|menu-bar-style|menu-bar-provider|support|diagnostics
--appearance system|light|dark
--text-size standard|extra-large|accessibility
```

Fixture mode starts no service and contains synthetic account, device, quota, cost, and coverage
data. Live mode uses the packaged service through the production IPC boundary. Generated `.build/`,
Rust `target/`, packaged apps, databases, and local preferences are development state and must not be
committed.
