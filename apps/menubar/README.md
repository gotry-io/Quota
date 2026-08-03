# QuotaBar

QuotaBar is the native SwiftUI macOS menu bar client. It displays local QuotaCLI snapshots and
remote snapshots from one or more persistent QuotaRelay profiles.

When polling starts, QuotaBar ensures there is one managed `Quota Relay` profile for
`https://quota.gotry.io`. If none exists, it verifies discovery, registers an anonymous controller,
stores the returned controller token only in Keychain, and persists non-secret profile metadata.
An unavailable managed service remains retryable on the next polling cycle and never blocks local
quota collection. Users may also add independent self-hosted Relay profiles by entering their base
URL and externally managed controller token.

The Relay core stores profile metadata separately from controller bearers, binds profiles to a
discovered Relay instance, and implements pairing decisions, snapshot reads, device listing, and
device revocation. It accepts protocol v1 Relays only when they advertise bearer authentication,
persistent snapshots, and instant device revocation. Credential and transport requirements are
defined in [`docs/security.md`](../../docs/security.md).

Deleting a managed profile first deletes its anonymous controller and linked Relay data; deleting a
self-hosted profile removes only QuotaBar's local profile and Keychain token because that controller
is managed externally. Removing the managed profile persists an enrollment opt-out across restarts;
**Reconnect Quota Relay** is the explicit action that creates a new anonymous controller. Settings
also provides **Delete all QuotaBar data**, which deletes managed controllers before clearing all
QuotaBar controller Keychain items, profiles, cached quota, and user preferences while retaining
only that opt-out. If the managed Relay cannot be reached, the confirmation flow offers an explicit
local-only fallback; the managed controller and Relay data may remain remotely while paired devices
continue reporting. Startup reconciliation removes orphaned QuotaBar controller Keychain items that
have no profile metadata.

The Relay state model coordinates profile mutation, pairing, last-known-good snapshot and device
state, explicit refresh, and a cancellable five-minute polling loop. The production app creates one
shared model for its lifecycle, Overview, and Settings stack and starts polling when the app starts.

The observation-preserving subscription resolver groups only globally scoped provider identities
across local and remote sources, keeps source-scoped observations separate, selects one preferred
snapshot without accumulating quota values, and retains every contributing source. The menu-panel
Overview presents that resolved result with compact local and remote provenance.

The current menu panel invokes its bundled QuotaCLI helper, combines its normalized results with
configured Relay observations, and supports manual refresh plus explicit loading, authentication,
unavailable, and error states. The panel is a window-style `MenuBarExtra` with an overview-rooted
system navigation stack, an embedded Settings hierarchy for Relay profiles, pairing, and devices,
flat provider rows, and system-semantic monochrome styling from `DESIGN.md`. Appearance inherits the
current macOS color scheme through SwiftUI and has no app-level appearance override.
Agents without an authenticated session are omitted from the overview. A provider row requires a
successful result with at least one available or stale quota window; Settings retains status and
visibility controls for all supported agents. QuotaBar caches only the last normalized, redacted
local report so subsequent launches render immediately while a background refresh runs. The release
workflow packages an arm64-only app with its helper, signs every executable with Developer ID,
notarizes and staples the bundle, publishes a GitHub Release, and updates the Homebrew Cask.

The release target is a Homebrew Cask from `gotry-io/homebrew-tap`. The signed `.app` contains the
standalone QuotaCLI helper at a fixed bundle path and invokes that copy instead of a `quotacli`
found on `PATH`. Users installing QuotaBar therefore do not install the npm CLI separately.

Provider artwork uses the monochrome Codex, Claude Code, and Grok SVG assets from Lobe Icons. The
source SVGs remain vector resources and render as semantic template images. See
[`THIRD_PARTY_NOTICES.md`](Sources/QuotaBar/Resources/THIRD_PARTY_NOTICES.md) for attribution.

## Visual QA

Build the Debug-only visual acceptance app from the repository root:

```bash
pnpm build:menubar:visual
```

Run the deterministic launch-and-screenshot acceptance matrix with `pnpm test:menubar:visual`.
Screenshots default to `dist/menubar-visual/screenshots`; use
`pnpm test:menubar:visual --no-build` to reuse the existing app or pass
`--output-dir <directory>` to select another screenshot directory. The visual app captures its own
window content via AppKit (no Screen Recording permission). Pass
`--screenshot-output <absolute path>` to request a PNG; relative paths are rejected and the default
is no capture. The matrix fails instead of accepting missing or empty captures.

`QuotaBarVisual.app` uses the real menu-panel views inside an independently identified, ordinary
macOS window. Its default `fixture` data source is deterministic: it does not invoke QuotaCLI or read
provider credentials, and the app does not write the production app's preferences. Launch a fixture
with:

```bash
open -n dist/menubar-visual/QuotaBarVisual.app --args \
  --data-source fixture --fixture content --route overview --appearance light
```

Fixtures are `loading`, `content`, `cached-refresh-error`, `empty`, and `unavailable`. Routes are
`overview`, `settings`, `relays`, `add`, `detail`, `pairing`, and `devices`; appearances are
`system`, `light`, and `dark`. Text sizes are `standard`, `extra-large`, and `accessibility`, selected
with `--text-size`.

The visual bundle also contains the same arm64 standalone QuotaCLI helper as the production app. An
explicit live run invokes that bundled helper and may read local Codex, Claude Code, or Grok provider
sessions according to [`docs/provider-collection.md`](../../docs/provider-collection.md):

```bash
open -n dist/menubar-visual/QuotaBarVisual.app --args \
  --data-source live --route overview --appearance system
```

Live mode does not reuse a cached report: each app launch starts one view-driven collection through
the production `LocalQuotaClient` boundary. The visual app therefore validates helper packaging,
process execution, wire decoding, and the shared menu-panel UI together. It does not reproduce the
menu-bar icon, popover anchor, click-outside dismissal, or other `MenuBarExtra` window chrome, which
retain a small manual smoke test.

Run `pnpm test:relay:e2e` from the repository root for the real self-hosted and managed
controller-path acceptance flows. It launches the signed Visual App through LaunchServices and uses
the production URLSession, `RelayStateModel`, UserDefaults, and system Keychain boundaries against a
temporary loopback Relay.
A test-only CLI runner injects one normalized non-empty collection report at the existing command
dependency boundary; pairing, credential persistence, upload sequencing, Relay storage, Overview
resolution, device revocation, rejection, restart restoration, and cleanup remain real. The flow
does not read ambient provider credentials or modify production QuotaBar preferences or Keychain
items.

Before uninstalling QuotaBar, use **Settings → Delete all QuotaBar data** while online. Dragging the
app to Trash cannot run cleanup code, and Homebrew Cask `zap` can remove preferences and saved window
state but cannot safely perform authenticated device revocation or delete signed Keychain items on
the app's behalf.
