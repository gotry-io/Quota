# Quota iOS

Quota is the native iOS 26+ account viewer. It signs in with the registered `quota-ios` public
client and reads the GitHub Account's remaining quota and Today Usage from the fixed Relay origin.
One read answers all of it: Relay resolves an account's readings into one subscription per key, so
the app renders those rows rather than collapsing one card per reporting Mac.
The app also publishes a non-secret App Group snapshot for Home Screen and Lock Screen widgets.
Widgets are configurable.

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
snapshots or Usage, or add `ios` to `PlatformSchema`. The Devices tab lists the collection Devices
with their platform and how recently each one spoke — Active, Idle, or Not reporting — without
requesting credentials for them. See
[ADR 0013](../../docs/decisions/0013-readonly-ios-account-client.md).

The detailed system boundary is in [`docs/architecture.md`](../../docs/architecture.md), security
requirements are in [`docs/security.md`](../../docs/security.md), and UI behavior is canonical in
[`DESIGN.md`](DESIGN.md).

## App Group and signing

App and extension entitlements both declare `group.io.gotry.quota` with
`CODE_SIGN_ENTITLEMENTS` set in `project.yml`. Production signing profiles for
`io.gotry.quota` and `io.gotry.quota.widgets` must include that App Group. Local simulator builds
may run with signing disabled for verification scripts.

## Background refresh

The app registers `io.gotry.quota.refresh` as a `BGAppRefreshTask` and asks for it no sooner than
thirty minutes out after every refresh that found a session. When the system grants a window, the
app process runs the same refresh a pull-to-refresh runs — Keychain session, last-good cache, one
Relay read — republishes the App Group snapshot, reloads widget timelines, asks for the next window,
and reports the outcome to the scheduler. A refresh that does not reach Relay leaves the published
snapshot in place and says nothing; Overview states the failed refresh the next time the app is
opened. Signing out, an expired session, and a launch with no session withdraw the pending request
instead: there is nothing to read, so there is nothing to be woken for. The extension is unchanged:
it still only reads the snapshot.

## Privacy manifest

The app target ships [`Sources/PrivacyInfo.xcprivacy`](Sources/PrivacyInfo.xcprivacy) and the
widget extension ships [`Widgets/PrivacyInfo.xcprivacy`](Widgets/PrivacyInfo.xcprivacy). Neither
tracks. The app declares the Account data Relay retains — a GitHub-subject HMAC account id
(`NSPrivacyCollectedDataTypeUserID`) and quota/usage summaries
(`NSPrivacyCollectedDataTypeOtherUsageData`) — linked, for App Functionality, matching the
retention list in [`docs/security.md`](../../docs/security.md). The extension collects nothing: it
only reads the App Group snapshot. Required-reason APIs are listed only when this target's code
calls them; neither target currently does.

After an Archive, use Xcode **Product › Generate Privacy Report** on the archive to confirm there
are no undeclared required-reason APIs (owner step).

## Development

From the repository root:

```bash
pnpm generate:ios
pnpm check:ios
pnpm test:ios
pnpm build:ios
pnpm version:bump:ios patch   # or minor | major | explicit semver
open apps/ios/Quota.xcodeproj
```

`pnpm generate:ios` runs the installed XcodeGen against `project.yml` and refreshes the checked-in
Xcode project. Do not add a third-party package manager. The app has no Sparkle or analytics.
App icon assets live in `Resources/Assets.xcassets`. App Store upload is the owner-only `ios-v*`
workflow below. Delete Account starts on the website.

`pnpm test:ios` runs `swift test` for `packages/apple-client` and the Quota scheme tests (`QuotaTests`
and `QuotaUITests`) on an available iPhone simulator (`QUOTA_IOS_SIMULATOR` overrides the name).
`pnpm build:ios` builds for the generic iOS Simulator. These commands are not part of root
`pnpm test` or `pnpm build`.

`pnpm version:bump:ios` updates `MARKETING_VERSION` in `project.yml` and regenerates the Xcode
project. Pass `--no-commit` to skip the commit.

### UI tests

`QuotaUITests` is XCUITest (not swift-testing) and launches DEBUG visual fixtures. It asserts
`overview.root` / `overview.today` for `content`, switches that fixture to the Usage tab for
`usage.root` / a model row at 30 Days / the Activity heatmap, opens the first quota card for
`subscription-detail`, the Mac setup card for `no-devices`, the Connect with GitHub control for
`signed-out`, connecting / connect-error / expired / loading fixtures, the inline GitHub account
confirmation for `confirm-account`, and Settings for the compact hub plus Notifications,
Appearance, and About destinations, and runs an accessibility audit on each. Connect's audit does
not skip contrast. Log Out and Delete Account sit on the Settings hub. Delete Account starts on
the website. Settings destinations run the full app-owned accessibility audit with no unnamed
clipping skip.

```bash
./scripts/ios-ui-screenshots.sh
```

That script runs only `QuotaUITests`, writes `dist/ios-ui.xcresult`, and exports PNG attachments to
`dist/ios-ui-screenshots/`. It uses `QUOTA_IOS_SIMULATOR` when set, otherwise the first available
iPhone from `xcrun simctl list devices available -j`. Screenshot artifacts are for local visual QA
and are not part of CI.

### DEBUG visual fixtures

DEBUG builds accept a launch argument that loads offline UI state for screenshots (no network or
Keychain restore):

```bash
# Example scheme arguments: --visual-fixture content
# Values: signed-out | connecting | connect-error | expired | confirm-account | loading | content | cached-error | empty | no-devices
```

See [`DESIGN.md`](DESIGN.md) for fixture contents and the full visual QA checklist.

## Release

Local signing values live in `apps/ios/Local.xcconfig`, which is gitignored. Copy
`Local.xcconfig.example` to that path and fill `DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE`, and the app
and widget `PROVISIONING_PROFILE_SPECIFIER` keys. XcodeGen 2.46 refuses a `configFiles` path that is
not on disk, so `project.yml` points at committed `Signing.xcconfig`, which optionally includes
`Local.xcconfig`. `settingGroups` plus environment substitution would stamp the team id into the
generated `project.pbxproj` at `pnpm generate:ios` time and is not used. Simulator verification
(`pnpm build:ios`, `pnpm test:ios`, `pnpm check:ios`) still passes `CODE_SIGNING_ALLOWED=NO` and
does not need the file.

The marketing version is `MARKETING_VERSION` in `project.yml`. Publishing is the tag alone:

```bash
git tag ios-vX.Y.Z
```

`.github/workflows/release-ios.yml` runs on `ios-v*` tags. `scripts/check-ios-version.sh` fails the
job unless the tag's `X.Y.Z` equals `MARKETING_VERSION`. The archive's `CURRENT_PROJECT_VERSION` is
`github.run_number`. The owner (not CI on an unsigned pull request) creates the tag after the
version is committed.

Repository secrets, all required before export:

| Secret | Contents |
| --- | --- |
| `IOS_DISTRIBUTION_CERT_P12` | Base64-encoded Apple Distribution `.p12` |
| `IOS_DISTRIBUTION_CERT_PASSWORD` | Password for that `.p12` |
| `IOS_PROFILE_APP` | Base64-encoded App Store `.mobileprovision` for `io.gotry.quota` |
| `IOS_PROFILE_WIDGETS` | Base64-encoded App Store `.mobileprovision` for `io.gotry.quota.widgets` |
| `ASC_KEY_ID` | App Store Connect API key id |
| `ASC_ISSUER_ID` | App Store Connect issuer id |
| `ASC_KEY_P8` | App Store Connect API key `.p8` PEM |

The workflow imports those into a temporary keychain, writes `Local.xcconfig` from the profile
metadata, archives, exports with `apps/ios/ExportOptions.plist` (`method` `app-store-connect`,
manual signing), and uploads with `xcrun altool --upload-app --apiKey --apiIssuer`. If any secret is
unset, the job fails before export. Do not put team ids, certificates, or profile names in tracked
files.
