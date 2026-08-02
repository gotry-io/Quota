# QuotaBar

QuotaBar is the native SwiftUI macOS menu bar client. It displays local QuotaCLI snapshots and
remote snapshots from one or more persistent QuotaRelay profiles.

The default managed Relay base URL is `https://quota.gotry.io`. Users may add independent
self-hosted Relay profiles with their own base URLs.

Relay credentials are referenced through Keychain identifiers; access tokens are never stored in
the profile model. The app first reads `/.well-known/quotabar-relay` and only accepts protocol v1
relays that advertise persistent snapshots.

The current menu panel invokes its bundled QuotaCLI helper, displays local normalized provider
results, and supports manual refresh plus explicit loading, authentication, unavailable, and error
states. Its appearance inherits the current macOS color scheme through SwiftUI and has no app-level
appearance override. Agents without an authenticated session are omitted from the overview. A
provider row requires a successful result with at least one available or stale quota window;
Settings retains status and visibility controls for all supported agents. QuotaBar caches only the
last normalized, redacted local report so subsequent launches render immediately while a
background refresh runs. Release packaging, signing, updates, Relay settings, and the helper
lifecycle will be added separately.

The release target is a Homebrew Cask from `gotry-io/homebrew-tap`. The signed `.app` contains the
standalone QuotaCLI helper at a fixed bundle path and invokes that copy instead of a `quotacli`
found on `PATH`. Users installing QuotaBar therefore do not install the npm CLI separately.

Provider artwork uses the monochrome Codex, Claude Code, and Grok SVG assets from Lobe Icons. The
source SVGs remain vector resources and render as semantic template images. See
[`THIRD_PARTY_NOTICES.md`](Sources/QuotaBar/Resources/THIRD_PARTY_NOTICES.md) for attribution.
