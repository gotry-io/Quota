# QuotaBar

QuotaBar is the native SwiftUI macOS menu bar client. It displays local QuotaCLI snapshots and
remote snapshots from one or more persistent QuotaRelay profiles.

The default managed Relay base URL is `https://quota.gotry.io`. Users may add independent
self-hosted Relay profiles with their own base URLs.

Relay credentials are referenced through Keychain identifiers; access tokens are never stored in
the profile model. The app first reads `/.well-known/quotabar-relay` and only accepts protocol v1
relays that advertise persistent snapshots.

The current target is a minimal SwiftUI bootstrap rather than a distributable `.app` bundle. App
packaging, signing, updates, Keychain access, and the helper lifecycle will be added separately.
