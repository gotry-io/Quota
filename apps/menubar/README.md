# QuotaBar

QuotaBar is the native SwiftUI macOS menu bar client. It displays local QuotaCLI snapshots and
remote snapshots from one or more persistent QuotaRelay profiles.

The default managed Relay base URL is `https://quota.gotry.io`. Users may add independent
self-hosted Relay profiles with their own base URLs.

The Relay core now stores profile metadata separately from owner bearers, binds profiles to a
discovered Relay instance, and implements pairing decisions, snapshot reads, device listing, and
device revocation. It accepts protocol v1 Relays only when they advertise bearer authentication,
persistent snapshots, and instant device revocation. Credential and transport requirements are
defined in [`docs/security.md`](../../docs/security.md).

The observation-preserving subscription resolver groups only globally scoped provider identities
across local and remote sources, keeps source-scoped observations separate, selects one preferred
snapshot without accumulating quota values, and retains every contributing source. The menu-panel
overview has not yet been switched from its local-only presentation to this resolver.

The current menu panel invokes its bundled QuotaCLI helper, displays local normalized provider
results, and supports manual refresh plus explicit loading, authentication, unavailable, and error
states. The panel is a window-style `MenuBarExtra` with an overview-rooted system navigation stack,
an embedded Settings hierarchy, flat provider rows, and system-semantic monochrome styling from
`DESIGN.md`. Appearance inherits the current macOS color scheme through SwiftUI and has no app-level
appearance override.
Agents without an authenticated session are omitted from the overview. A provider row requires a
successful result with at least one available or stale quota window; Settings retains status and
visibility controls for all supported agents. QuotaBar caches only the last normalized, redacted
local report so subsequent launches render immediately while a background refresh runs. The release
workflow packages an arm64-only app with its helper, signs every executable with Developer ID,
notarizes and staples the bundle, publishes a GitHub Release, and updates the Homebrew Cask. Relay
polling, resolver integration, Settings orchestration, and remote-device UI remain separate
milestones.

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

`QuotaBarVisual.app` uses the real menu-panel views inside an independently identified, ordinary
macOS window. Its default `fixture` data source is deterministic: it does not invoke QuotaCLI or read
provider credentials, and the app does not write the production app's preferences. Launch a fixture
with:

```bash
open -n dist/menubar-visual/QuotaBarVisual.app --args \
  --data-source fixture --fixture content --route overview --appearance light
```

Fixtures are `loading`, `content`, `cached-refresh-error`, `empty`, and `unavailable`. Routes are
`overview` and `settings`; appearances are `system`, `light`, and `dark`. Text sizes are `standard`,
`extra-large`, and `accessibility`, selected with `--text-size`.

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
