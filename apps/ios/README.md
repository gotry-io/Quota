# Quota iOS

Quota is the native iOS 17+ account viewer. It signs in with the registered `quota-ios` public
client and reads the GitHub Account's remaining quota and Today Usage from the fixed Relay origin.
The app also publishes a non-secret App Group snapshot for Home Screen and Lock Screen widgets.

## Runtime boundary

The app owns SwiftUI, `ASWebAuthenticationSession`, UI preferences, App Group snapshot publish/clear,
and WidgetKit timeline reloads. [`packages/apple-client`](../../packages/apple-client)
owns wire decoding, PKCE values, the fixed-origin HTTPS client, session refresh/revoke, Keychain
session storage, last-good Account summary cache, and the Foundation-only `QuotaWidgetData`
snapshot types/store. [`packages/apple-shared`](../../packages/apple-shared)
owns remaining-quota, plan/account label, compact count, Usage cost, and compact relative-age
presentation. Views never call `URLSession`, Security, or decode JSON. `QuotaWire` is the one definition of the
managed wire types and `ProviderID`; QuotaBar reads the same module, so a decoding rule written once
protects both products.

The embedded `QuotaWidgets` extension (`io.gotry.quota.widgets`) depends only on `QuotaWidgetData`
and `QuotaPresentation`. It reads the App Group protected snapshot and never imports account wire,
Relay, session, Security, or network APIs. See
[ADR 0014](../../docs/decisions/0014-nonsecret-ios-widget-snapshot.md).

Quota iOS is not a collection Device. It does not configure Providers, collect local logs, upload
snapshots or Usage, or add `ios` to `PlatformSchema`. Overview lists the collection Devices with
their platform and how recently each one spoke — Active, Idle, or Not reporting — without requesting
credentials for them. See
[ADR 0013](../../docs/decisions/0013-readonly-ios-account-client.md).

The detailed system boundary is in [`docs/architecture.md`](../../docs/architecture.md), security
requirements are in [`docs/security.md`](../../docs/security.md), and UI behavior is canonical in
[`DESIGN.md`](DESIGN.md).

## App Group and signing

App and extension entitlements both declare `group.io.gotry.quota` with
`CODE_SIGN_ENTITLEMENTS` set in `project.yml`. Production signing profiles for
`io.gotry.quota` and `io.gotry.quota.widgets` must include that App Group. Local simulator builds
may run with signing disabled for verification scripts.

## Development

From the repository root:

```bash
pnpm generate:ios
pnpm check:ios
pnpm test:ios
pnpm build:ios
open apps/ios/Quota.xcodeproj
```

`pnpm generate:ios` runs the installed XcodeGen against `project.yml` and refreshes the checked-in
Xcode project. Do not add a third-party package manager. The app has no Sparkle, background
network task, notification, analytics, or App Store upload workflow.

`pnpm test:ios` runs `swift test` for `packages/apple-client` and, when an iPhone 17 Pro simulator is
available, the Quota iOS unit tests. `pnpm build:ios` builds for the generic iOS Simulator. These
commands are not part of root `pnpm test` or `pnpm build`.

### DEBUG visual fixtures

DEBUG builds accept a launch argument that loads offline UI state for screenshots (no network or
Keychain restore):

```bash
# Example scheme arguments: --visual-fixture content
# Values: signed-out | content | cached-error | empty
```

See [`DESIGN.md`](DESIGN.md) for fixture contents and the full visual QA checklist.
