# Quota iOS

Quota is the native iOS 26+ quota app. It reads two things and shows one list.

It signs in to a provider's own web session on the phone and reads that provider on this device,
which is all it needs to be useful — no Quota account required. With one, it also signs in with the
registered `quota-ios` public client and reads the Account's remaining quota and Today Usage
from the fixed Relay origin; Relay resolves an account's readings into one subscription per key, so
the app renders those rows rather than one card per reporting Mac. Overview is the two merged by
the rule in [ADR 0003](../../docs/decisions/0003-observation-preserving-subscription-merge.md), so
an account both a Mac and this phone read is one row with both sources. The app also publishes a
non-secret App Group snapshot for Home Screen and Lock Screen widgets. Home Screen families show
remaining quota (small: one subscription, two windows; medium: up to three providers; large: three
providers × two windows plus Today). Lock Screen families show Weekly used percent and
**Resets in …**; rectangular adds the second window. Widgets are configurable.

## Signing in

There are three ways in, and they reach one Account
([ADR 0032](../../docs/decisions/0032-an-account-owns-its-identities.md)). **Continue with Apple**
asks on the device and posts the identity token Apple signed to `POST /oauth/v2/apple`. **Continue
with GitHub** and **Continue with Email** open the same Relay authorize URL in
`ASWebAuthenticationSession`, because Relay's `/sign-in` page is what asks which Account this is
and offers every channel that reaches one. GitHub finishes inside that sheet; the emailed link is
opened by the mail app, so it finishes in the system browser and Relay's redirect to
`io.gotry.quota:/oauth/callback` reaches the app as a URL open, which the app exchanges against the
attempt it is still holding before ending the sheet.

**Settings › Sign-in methods** lists `GET /api/v2/account`'s `identities[]` and binds Apple on the
device with `intent: link`. Every other bind, and every unbind, opens
`https://quota.gotry.io/sign-in?return_to=%2Fmy%2Fsettings` in the browser: binding writes to an
Account, and unbinding is a destructive change the website asks for a recent sign-in before
allowing. UI behaviour is canonical in [`DESIGN.md`](DESIGN.md).

## Runtime boundary

The app owns SwiftUI, `ASWebAuthenticationSession`, UI preferences, App Group snapshot publish/clear,
and WidgetKit timeline reloads. [`packages/apple-client`](../../packages/apple-client)
owns wire decoding, PKCE values, the fixed-origin HTTPS client, session refresh/revoke, Keychain
session storage, last-good Account summary cache, the provider web collectors
(`QuotaProviderWeb`) and their Keychain store (`QuotaProviderSessions`), and the Foundation-only
`QuotaWidgetData` snapshot types/store. The app owns the local collection pass over those sessions
and the app-container file holding its result.
[`packages/apple-shared`](../../packages/apple-shared) owns remaining-quota, plan/account label,
compact count, Usage cost, and compact relative-age presentation, and — in `QuotaObservations` —
the subscription key and the observation merge this app resolves Overview with. Views never call `URLSession`, Security, or decode JSON. `QuotaWire` is the one definition of the
managed wire types and `ProviderID`; QuotaBar reads the same module, so a decoding rule written once
protects both products.

The embedded `QuotaWidgets` extension (`io.gotry.quota.widgets`) depends only on `QuotaWidgetData`
and `QuotaPresentation`. It reads the App Group protected snapshot and never imports account wire,
Relay, session, Security, or network APIs. See
[ADR 0014](../../docs/decisions/0014-nonsecret-ios-widget-snapshot.md).

Quota Pro is bought here. `apps/ios` is the only target that depends on the
RevenueCat `purchases-ios` SDK (SPM, pinned to an exact version in `project.yml`);
`packages/apple-client` does not, so QuotaBar and the widget extension link no store code.
`RevenueCatPurchases` is the one file that imports it, behind the app-local `PurchasesFacade`, and
`Purchases.logIn` binds a purchase to the Quota Account id so RevenueCat's `app_user_id` is the
`accounts.id` Relay gates writes on. What Quota Pro is *worth* is never read from the SDK: the
`entitlement` on the Account summary is, because that is the same row the Relay write routes
refuse a Device with. See [ADR 0033](../../docs/decisions/0033-entitlement-is-read-from-revenuecat.md).

Quota iOS is a Device. Signing in presents this phone's installation — one Keychain item,
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and not synchronized, so a restored backup is
not a second phone claiming the same Device — with the name the system gives this device and
`platform: ios`, and the session it gets names that Device. Each refresh that read something then
asks `GET /api/v2/device/sync` for the generation an envelope must name and sends the readings to
`PUT /api/v6/device/snapshots`; a 402 stops that refresh and shows the sync-off banner, and the
next refresh asks again. Only readings go: the provider cookies stay in this device's Keychain,
and no Usage is uploaded because this phone runs no agent. See
[ADR 0041](../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md).

The Devices tab is the Account's, so it asks for a sign-in when there is no account; with one it
lists the Devices with their platform and how recently each one spoke — Active, Idle, or Not
reporting — without requesting credentials for them. This phone is one of those rows once the
Account lists it; a session that named no Device still draws **This iPhone** for what it read
itself.

It does sign in to a provider for itself. **Settings › Providers** connects Codex, Claude Code,
and Grok by opening that provider's own sign-in page in a `WKWebView` whose data store is
non-persistent and made new for each sheet. After each navigation the sheet reads that store's
cookies, assembles the header `packages/provider/catalog.json` declares, and keeps it only when
`QuotaProviderWeb` validates it against the provider. Accepted sessions live in this device's
Keychain — one item per provider and account fingerprint,
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronized to iCloud — and are never
uploaded. The first Connect for a provider asks for consent naming that provider's cookies and
hosts. Nothing is injected into the page and no page content is read.

Every refresh — pull-to-refresh and background alike — reads every stored session in parallel and
writes the result to `local-observations.json` in the app container, beside the Account summary
cache and under the same protection. That file holds readings, never a cookie. A provider that
refuses a cookie marks that session **Sign in again** in Settings; one that could not be reached
leaves no mark. A successful read moves that session's `lastValidatedAt`, which is the
"Checked …" age the Providers list shows. See
[ADR 0034](../../docs/decisions/0034-ios-collects-for-itself.md).

The detailed system boundary is in [`docs/architecture.md`](../../docs/architecture.md), security
requirements are in [`docs/security.md`](../../docs/security.md), and UI behavior is canonical in
[`DESIGN.md`](DESIGN.md).

## App Group and signing

App and extension entitlements both declare `group.io.gotry.quota` with
`CODE_SIGN_ENTITLEMENTS` set in `project.yml`. Production signing profiles for
`io.gotry.quota` and `io.gotry.quota.widgets` must include that App Group. Local simulator builds
may run with signing disabled for verification scripts.

## RevenueCat key

The SDK is configured from the Info.plist key `REVENUECAT_IOS_API_KEY`, which the build setting of
the same name fills. Local builds get it from `apps/ios/Local.xcconfig` (gitignored; see
`Local.xcconfig.example`), and the release workflow writes it into that file from the
`REVENUECAT_IOS_API_KEY` repository secret. Only the **public** iOS SDK key belongs here; the
secret REST key and the webhook authorization value are Relay's, listed in
[`apps/relay/README.md`](../relay/README.md).

A build with no key does not configure the SDK at all. `AppModel` gets `UnconfiguredPurchases`
instead, Settings › Quota Pro still shows what Relay says the Account is entitled to, and the paywall
says **Purchases unavailable in this build.** in place of the plans. That is what
`pnpm build:ios`, `pnpm check:ios`, `pnpm test:ios`, and every unsigned pull-request build are.

## StoreKit configuration

`apps/ios/Quota.storekit` stands in for App Store Connect while the products do not exist there
yet. It declares one subscription group, **Quota Pro**, with `quota_pro_monthly` ($0.99) and
`quota_pro_yearly` ($2.99), each with a seven-day free introductory offer. `project.yml` sets it as the
Quota scheme's `storeKitConfiguration`, so running the app from Xcode buys against it instead of
the App Store; delete the app from the simulator to reset the test store. The paywall also offers
Apple's **Redeem Offer Code** sheet; there is no typed license-key field.

`QuotaTests` ships the same file as a bundle resource, and `StoreKitConfigurationTests` reads it:
one group, the two product ids `SubscriptionTerm` names, the durations they are sold for, the
seven-day free trial on each, and nothing else for sale. That runs in `pnpm test:ios` with no App
Store account and no network.

Buying is not exercised there. `SKTestSession` cannot be used under `xcodebuild test` on Xcode
26.3: every call answers `Error Domain=SKInternalErrorDomain Code=3` and no product resolves,
because the configuration never reaches the simulator's `storekitd`. Exercise a purchase by
running the Quota scheme from Xcode, which does hand it over — buy monthly, then use the
Transactions inspector to refund or expire it. RevenueCat itself is not exercised either way; an
SDK-level purchase needs a RevenueCat project and key.

## Background refresh

The app registers `io.gotry.quota.refresh` as a `BGAppRefreshTask` and asks for it no sooner than
thirty minutes out after every refresh, while this phone has anything to read: an account session,
a provider session, or both. When the system grants a window, the app process runs the same refresh
a pull-to-refresh runs — the local collection pass over its provider sessions, and, with an account,
the Keychain session, last-good cache and one Relay read — merges them, republishes the App Group
snapshot, reloads widget timelines, asks for the next window, and reports the outcome to the
scheduler. Local collection there is bounded at twenty seconds; a pass that runs past it leaves the
last reading in place. A refresh that learns nothing leaves the published snapshot alone and says
nothing; Overview states the failed refresh the next time the app is opened. A phone with neither
an account nor a provider session withdraws the pending request: there is nothing to read, so there
is nothing to be woken for. The extension is unchanged: it still only reads the snapshot.

## Privacy manifest

The app target ships [`Sources/PrivacyInfo.xcprivacy`](Sources/PrivacyInfo.xcprivacy) and the
widget extension ships [`Widgets/PrivacyInfo.xcprivacy`](Widgets/PrivacyInfo.xcprivacy). Neither
tracks. Provider sign-in cookies are not a declared collection: they stay in this device's Keychain
and are sent only to the provider they came from, so no App Privacy type covers them. Keychain is
not a required-reason API, so `NSPrivacyAccessedAPITypes` stays empty. The app declares the Account
data Relay retains — a GitHub-subject HMAC account id
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
`usage.root` / a model row at 30 Days / the Activity heatmap / **View day** and the populated day
sheet, plus Usage empty / activity-loading / activity-failed / day-empty / day-failed fixtures,
opens the first quota row for `subscription-detail`, empty quota/Today for `empty`, the compact Mac
setup Section for `no-devices`, the Providers group's three connection states plus a refused
session for `providers`, Devices content and empty states, the cached-error status Label, the two
invitations on the empty Overview for `signed-out`, the locally collected Overview and its
**This iPhone** reading for `local-only`, the one merged row for `merged`, connecting /
connect-error / expired / loading fixtures, the inline GitHub account confirmation for `confirm-account`, and Settings for the compact
hub plus Notifications, Appearance, and About destinations, and runs an accessibility audit on each.
Overview and Usage scroll to assert tab-bar minimization. Connect, Overview, subscription detail,
Devices, Usage, and the Settings destinations run the app-owned audit, including contrast, with no
unnamed clipping skip and no whole-type contrast skip. Log Out and Delete Account sit on the
Settings hub. Delete Account starts on the website.

```bash
./scripts/ios-ui-screenshots.sh
QUOTA_IOS_APPEARANCE=dark ./scripts/ios-ui-screenshots.sh
QUOTA_IOS_TEXT_SIZE=accessibilityExtraLarge ./scripts/ios-ui-screenshots.sh
```

That script runs only `QuotaUITests`, writes `dist/ios-ui.xcresult`, and exports PNG attachments to
`dist/ios-ui-screenshots/`. It uses `QUOTA_IOS_SIMULATOR` when set, otherwise the first available
iPhone from `xcrun simctl list devices available -j`. `QUOTA_IOS_TEXT_SIZE` (SwiftUI `DynamicTypeSize`
name or a `UICTContentSizeCategory*` value) and `QUOTA_IOS_APPEARANCE` (`light` or `dark`) are
forwarded to the UI tests; variant runs write a subdirectory. Screenshot artifacts are for local
visual QA and are not part of CI.

### DEBUG visual fixtures

DEBUG builds accept a launch argument that loads offline UI state for screenshots (no network or
Keychain restore):

```bash
# Example scheme arguments: --visual-fixture content
# Values: signed-out | connecting | connect-error | expired | confirm-account | connect-refresh-failed | loading | content | cached-error | empty | no-devices | local-only | merged | providers | activity-loading | activity-failed | activity-day-empty | activity-day-failed | sync-off | sync-active | sync-lifetime | paywall | paywall-unavailable
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
| `REVENUECAT_IOS_API_KEY` | RevenueCat public iOS SDK key (`appl_…`) |

The workflow imports those into a temporary keychain, writes `Local.xcconfig` from the profile
metadata, archives, exports with `apps/ios/ExportOptions.plist` (`method` `app-store-connect`,
manual signing), and uploads with `xcrun altool --upload-app --apiKey --apiIssuer`. If any secret is
unset, the job fails before export. Do not put team ids, certificates, or profile names in tracked
files.
