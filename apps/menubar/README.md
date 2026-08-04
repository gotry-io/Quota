# QuotaBar

QuotaBar is the native SwiftUI macOS menu bar client. It displays local QuotaCLI snapshots and
remote snapshots from devices this QuotaBar has paired through one or more Relay endpoints.

Pair Device enrolls an isolated anonymous owner capability for the selected Relay URL (official or
custom), stores the returned bearer only in a user-only Application Support file, and keeps endpoint
records as internal state. Users never enter owner tokens, profile names, or admin credentials. Local
collection is independent of Relay availability.

The Relay core binds each endpoint to a discovered instance and implements pairing decisions,
snapshot reads, device listing, and device revocation for that QuotaBar's private group only. It
accepts protocol v1 Relays that advertise bearer authentication, persistent snapshots, instant
device revocation, and isolated multi-owner groups. Credential and transport requirements are
defined in [`docs/security.md`](../../docs/security.md) and
[`docs/decisions/0005-url-only-relay-enrollment.md`](../../docs/decisions/0005-url-only-relay-enrollment.md).

Settings exposes **Remote Devices** (aggregated own devices) and **Pair Device**. **Delete all
QuotaBar data** deletes each reachable owner group before clearing the local owners file, endpoint
records, cached quota, and preferences. If a Relay is unreachable, the confirmation flow offers an
explicit local-only fallback. Startup reconciliation removes orphaned owner records that have no
endpoint record. When an explicitly selected endpoint has lost or expired private access, Pair Device
replaces that unusable local record with a newly isolated owner; background polling never enrolls on
its own.

The Relay state model coordinates endpoint enrollment, pairing, last-known-good snapshot and device
state, explicit refresh, and a cancellable five-minute polling loop. The production app creates one
shared model for its lifecycle, Overview, and Settings stack and starts polling when the app starts.

The observation-preserving subscription resolver groups only globally scoped provider identities
across local and remote sources, keeps source-scoped observations separate, selects one preferred
snapshot without accumulating quota values, and retains every contributing source. The menu-panel
Overview presents that resolved result with compact local and remote provenance.

The current menu panel invokes its bundled QuotaCLI helper, combines its normalized results with
configured Relay observations, and supports manual refresh plus explicit loading, authentication,
unavailable, and error states. The panel is a window-style `MenuBarExtra` with an overview-rooted,
strongly typed page stack rendered inside one shared shell. Settings, Remote Devices, and Pair
Device use the shell's single custom back control rather than a system navigation bar. The panel
keeps flat provider rows, system-material chrome, monochrome provider marks, and restrained
semantic usage meters described in [`DESIGN.md`](./DESIGN.md). Appearance inherits the current macOS color scheme
through SwiftUI and has no app-level appearance override. Do not apply `apps/web/DESIGN.md` tokens
to the menu panel.
Agents without an authenticated session are omitted from the overview. A provider row requires a
successful result with at least one available or stale quota window; Settings retains status and
visibility controls for all supported agents. QuotaBar caches only the last normalized, redacted
local report so subsequent launches render immediately while a background refresh runs. The release
workflow packages an arm64-only app with its helper, signs every executable with Developer ID,
notarizes and staples the bundle, and publishes a GitHub Release. **Stable** tags also update the
Homebrew Cask; **prerelease** tags publish a GitHub prerelease ZIP only and skip Homebrew.

The stable release target is a Homebrew Cask from `gotry-io/homebrew-tap`. Beta builds are installed
from the GitHub prerelease ZIP. The signed `.app` contains the standalone QuotaCLI helper at a fixed
bundle path and invokes that copy instead of a `quotacli` found on `PATH`. Users installing QuotaBar
therefore do not install the npm CLI separately.

Provider artwork uses the monochrome OpenAI, Claude, and Grok SVG assets from Lobe Icons
(https://lobehub.com/icons). The source SVGs remain vector resources and render as semantic template
images. See [`THIRD_PARTY_NOTICES.md`](Sources/QuotaBar/Resources/THIRD_PARTY_NOTICES.md) for
attribution.

## Visual QA

Build the Debug-only visual acceptance app from the repository root:

```bash
pnpm build:menubar:visual
```

Run the deterministic launch-and-screenshot acceptance matrix with `pnpm test:menubar:visual`.
Screenshots default to `dist/menubar-visual/screenshots`; use
`pnpm test:menubar:visual --no-build` to reuse the existing app or pass
`--output-dir <directory>` to select another screenshot directory. The visual app captures its own
window content via AppKit (no Screen Recording permission). Its deterministic window background is
opaque so pixel validation can detect blank or transparent captures and lost foreground/background
contrast. Standard and accessibility renders of the same routes must also differ. Pass
`--screenshot-output <absolute path>` to request a PNG; relative paths are rejected and the default
is no capture. The matrix validates fixed panel dimensions, opaque pixels, luminance range, and
meaningful accessibility-size rendering in addition to rejecting missing or empty captures.

`QuotaBarVisual.app` uses the real menu-panel views inside an independently identified, ordinary
macOS window. Its default `fixture` data source is deterministic: it does not invoke QuotaCLI or read
provider credentials, and the app does not write the production app's preferences. Launch a fixture
with:

```bash
open -n dist/menubar-visual/QuotaBarVisual.app --args \
  --data-source fixture --fixture content --route overview --appearance light
```

Fixtures are `loading`, `content`, `cached-refresh-error`, `empty`, and `unavailable`. Routes are
`overview`, `settings`, `remote-devices`, and `pair-device`; appearances are `system`, `light`, and
`dark`. Text sizes are `standard`, `extra-large`, and `accessibility`, selected with `--text-size`.

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

Run `pnpm test:relay:e2e` from the repository root for the real self-hosted and managed owner-path
acceptance flows. It launches the signed Visual App through LaunchServices and uses
the production URLSession, `RelayStateModel`, UserDefaults, and an isolated owners file against a
temporary loopback Relay.
A test-only CLI runner injects one normalized non-empty collection report at the existing command
dependency boundary; pairing, credential persistence, upload sequencing, Relay storage, Overview
resolution, device revocation, rejection, restart restoration, and cleanup remain real. The flow
does not read ambient provider credentials or modify production QuotaBar preferences or owners file.

Before uninstalling QuotaBar, use **Settings → Delete all QuotaBar data** while online. Dragging the
app to Trash cannot run cleanup code, and Homebrew Cask `zap` can remove preferences and saved window
state but cannot safely perform authenticated device revocation or delete the owners file on the
app's behalf.
