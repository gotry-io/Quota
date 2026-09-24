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
providers × two windows plus Today). Lock Screen families show Weekly remaining percent and
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
allowing. Shared visual language is in [`docs/design.md`](../../docs/design.md); iOS platform
deltas are in [`DESIGN.md`](DESIGN.md).

## Runtime boundary

The app owns SwiftUI, `ASWebAuthenticationSession`, UI preferences, App Group snapshot publish/clear,
and WidgetKit timeline reloads. [`packages/apple-client`](../../packages/apple-client)
owns wire decoding, PKCE values, the fixed-origin HTTPS client, session refresh/revoke, Keychain
session storage, last-good Account summary cache, the Account usage cache (period and activity
bodies with their ETags beside the summary, cleared on sign-out), the Account settings document
(`GET` / `PUT /api/v2/account/settings`, cached beside the summary, cleared on sign-out),
the provider web collectors
(`QuotaProviderWeb`) and their Keychain store (`QuotaProviderSessions`), and the Foundation-only
`QuotaWidgetData` snapshot types/store. The app owns the local collection pass over those sessions
and the app-container file holding its result. Alert policy and the monthly budget follow the
Account when signed in
([ADR 0061](../../docs/decisions/0061-alert-policy-and-the-budget-follow-the-account.md));
`enabled` and delivery stay on this iPhone. The last local values keep working signed out.
A local policy edit is applied immediately, written with `If-Match`, and on 412 replayed once
onto the fresh document. Un-acknowledged edits are an ordered list per Account under
`accountSettings.pendingEdits` (the old single-record `accountSettings.pendingEdit` is
migrated into that list on load and then deleted). A later edit of the same target replaces
the earlier one; different targets append. One PUT folds the whole list. A second 412 or an
offline write keeps the local values and retries that snapshot; an edit that arrives while a
write is in flight is not cleared by that write's success. Pending edits for another Account
stay queued and are not sent. First sync is remembered per Account id in
`accountSettings.firstSyncAccountIDs`.
[`packages/apple-shared`](../../packages/apple-shared) owns remaining-quota, plan/account label,
compact count, Usage cost, and compact relative-age presentation, and — in `QuotaObservations` —
the subscription key and the observation merge this app resolves Overview with. Views never call `URLSession`, Security, or decode JSON. `QuotaWire` is the one definition of the
managed wire types and `ProviderID`; QuotaBar reads the same module, so a decoding rule written once
protects both products.

The embedded `QuotaWidgets` extension (`io.gotry.quota.widgets`) depends only on `QuotaWidgetData`
and `QuotaPresentation`. It reads the App Group protected snapshot and never imports account wire,
Relay, session, Security, or network APIs. See
[ADR 0014](../../docs/decisions/0014-nonsecret-ios-widget-snapshot.md).

Quota iOS is a Device. Signing in presents this phone's installation — one Keychain item,
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and not synchronized, so a restored backup is
not a second phone claiming the same Device — with the name the system gives this device and
`platform: ios`, and the session it gets names that Device. Each refresh that read something then
asks `GET /api/v2/device/sync` for the generation an envelope must name and sends the readings to
`PUT /api/v6/device/snapshots`. Only readings go: the provider cookies stay in this device's Keychain,
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

## Launch

A cold signed-in launch reads the two local collection files off the main actor, then one
Account-client hop that returns the Keychain session (one read, memoised for the rest of the
refresh), the last-good Account summary, and the usage cache. That is first content: Overview
shows the cached summary or local readings without waiting for Relay. The spinner is only the
launching phase when nothing is on disk yet.

Refresh then runs local collection beside the Account summary. Provider status is not on that
path: it is one unauthenticated `GET /api/v2/providers/status` (direct Statuspage polls only if
that read fails), started without waiting, and skipped when a sweep has just run. Device sync and
snapshot upload follow the summary but are not awaited; they feed Relay, not the screen. An access
token within 60 seconds of expiry is refreshed before the summary is asked for, so a still-good
token is one Relay round trip and an expired one is refresh-then-summary. The 401 path stays as
the safety net. Concurrent callers share one in-flight refresh.

The Account session Keychain item is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. A
background refresh that cannot read the Keychain is "cannot tell" and leaves the signed-in state
alone.

The detailed system boundary is in [`docs/architecture.md`](../../docs/architecture.md), security
requirements are in [`docs/security.md`](../../docs/security.md), shared visual language is in
[`docs/design.md`](../../docs/design.md), and iOS platform deltas are in
[`DESIGN.md`](DESIGN.md).

## App Group and signing

App and extension entitlements both declare `group.io.gotry.quota` with
`CODE_SIGN_ENTITLEMENTS` set in `project.yml`. Production signing profiles for
`io.gotry.quota` and `io.gotry.quota.widgets` must include that App Group. Local simulator builds
may run with signing disabled for verification scripts.

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
and `QuotaUITests`). It selects an explicit Xcode / runtime / device tuple through
`scripts/ios-simulator.py` — `QUOTA_IOS_XCODE`, `QUOTA_IOS_RUNTIME` and `QUOTA_IOS_SIMULATOR` pin
each, otherwise the newest `/Applications/Xcode*.app`, the newest available iOS runtime, and the first
preferred model on it — and prints that tuple, the text size and the appearance at the top of the
run's log and, in CI, in the job's step summary.
`pnpm build:ios` builds for the generic iOS Simulator. These commands are not part of root
`pnpm test` or `pnpm build`.

`pnpm version:bump:ios` updates `MARKETING_VERSION` in `project.yml` and regenerates the Xcode
project. Pass `--no-commit` to skip the commit.

### UI tests

The UI tests are XCUITest (not swift-testing) and launch DEBUG visual fixtures. They are two
classes with two jobs:

**`QuotaSmokeUITests` — the required gate** (`verify-ios-ui`, `QuotaUITests/QuotaSmokeUITests`).
Journeys and interaction contracts, **no accessibility audit and no screen census**: Overview's
Today row opens Usage already on Today and a quota row opens subscription detail and comes back;
Usage opens breakdown and Activity patterns, a day sheet from View day, and returns; the period menu
says Today with Today's headline once Today is chosen, and a fixed custom range (August 8 – 12, 2026,
picked day by day in the sheet's calendars) is applied, the sheet goes, and the title and headline are
that range's; Settings opens Notifications, Appearance and About and returns, with Log Out still on
the hub; Settings › Devices is its own journey; the Overview's **Sign in to Quota** opens the sign-in
sheet with every way in, and pulling the sheet down returns to the same Overview; the connecting,
pending-refresh, confirm-account and local-only states assert the controls they offer, the local-only
reading opens its detail and comes back and its Settings has no Devices row, and a refused provider
session offers **Sign in again** (the affordance — the provider login it starts leaves the
fixture). It also asserts the seven essential values — Overview remaining, Today tokens, cost and
the combined Today label, Usage headline tokens and cost, subscription remaining — at
`accessibilityExtraLarge`, the size that truncates first: each exists, is hittable, carries its
whole accessibility label and sits on screen.

A journey taps a control only when it is ready, the way a person could: it exists, is enabled, is
hittable, has held the same frame across two samples, and lies inside the viewport the navigation
and tab bars leave uncovered (`waitUntilReady` in `QuotaUITestSupport.swift`, which nudges a row
into view by the distance it is out, and fails naming what it saw). A back tap waits for the screen
it left to disappear before the next assertion, and a sheet or menu is waited out the same way; no
step of that sleeps for a fixed time. One second tap is made only when the destination did not appear
and the control is still ready — a dropped tap — and is reported as `recovered-on-retry`, which the
job summary counts. `scripts/ios-ui-run-summary.mjs` then checks the selection by identity: every
`test…()` method `QuotaSmokeUITests.swift` declares must have executed (passed or failed, not
skipped or result-less), and no other method or class may have run, so a missing, renamed or skipped
journey fails the job even when the count still looks right.

**`QuotaScreenUITests` — the advisory census** (`.github/workflows/ios-screens.yml`, not a required
check, nightly on main and on iOS-touching pull requests). One screen or state per test, launched
straight onto it with `--route` or a fixture whose first screen it is — no census test taps through
one screen to reach another, so a finding on one cannot hide the next one's evidence. It also owns
what each screen says: About's copy and links, the Providers matrix (Remove, Connect, Add Account;
Sign in again is the journey's) at every profile's size, and the
local-only and merged details' history and sources. The same identity check runs on its
`QuotaScreenUITests.swift` methods. Screens are captured light/large, dark/large and
light/`accessibilityExtraLarge` (nightly adds dark/large-type), and audited with the app-owned
auditor including contrast. Each screen audit attaches `audit-outcome.<screen>` JSON with one
outcome per type — `passed`, `confirmed` (same finding on two passes), `unconfirmed` (first pass
only), or `incomplete` (timed out) — plus exempted counts and the raw first- and second-pass
findings, including nil-element and exempted issues. Confirmed non-contrast findings fail that
workflow; contrast never gates; incomplete does not fail. Unnamed glass (`issue.element == nil`)
stays recorded and non-gating: the auditor names no element to fix. Kept exemptions are one audit
type, one identifier or exact label, and one screen, each with a reason (iOS 26.3 auditor
limitations on system list chrome, Form inner labels, combined-row inner text including Usage
budget, Settings appearance/budget, and breakdown count rows, wrapping subscription-detail history
and readings titles, and the sheet Done control). `scripts/ios-ui-audit-summary.mjs` prints those
outcomes from an `.xcresult`.

Because `incomplete` never fails, a screen whose audit times out every night is never audited and
nothing says so, so the nightly run also judges the trend. `scripts/ios-audit-trend.mjs` reads the
`ios-screens` artifacts of the recent nightly runs and reddens the nightly job when a
(profile, screen, test) has no completed non-contrast audit in its last five **eligible** runs. A run
counts for a screen only when that screen appears in it: a skipped test, a profile that was not
captured, a screen added later, and a run whose 14-day artifact has expired neither count towards the
five nor reset them. Completed means none of the non-contrast types the record reports is
`incomplete`; contrast is excluded, as the audit policy in `DESIGN.md` states. The gate stores
nothing, opens or updates one issue — `iOS screens: audits not completing` — and closes it when the
trend clears. It runs on the nightly and manual runs on main, never on a pull request, and never
blocks a merge.

**What that trades.** Copy of the error and empty variants, About's words and links, the Providers
matrix beyond the refused session, dark-mode rendering, the broad Dynamic
Type and contrast audits and most large-type reachability no longer block a merge; they are reported
by `ios-screens`, and a confirmed finding there is a defect to fix. Log Out and Delete Account sit
on the Settings hub; Delete Account starts on the website.

```bash
./scripts/ios-ui-screenshots.sh
QUOTA_IOS_APPEARANCE=dark ./scripts/ios-ui-screenshots.sh
QUOTA_IOS_TEXT_SIZE=accessibilityExtraLarge ./scripts/ios-ui-screenshots.sh
```

That script runs only `QuotaUITests/QuotaScreenUITests` (the census class), writes
`dist/ios-ui.xcresult`, and exports PNG attachments to
`dist/ios-ui-screenshots/`; the names it exports are the `attachScreenshot` names in
`QuotaScreenUITests.swift`. Which simulator it uses is `scripts/ios-simulator.py`, the one
selection `test-ios.sh` and the store screenshots share: `QUOTA_IOS_RUNTIME` and
`QUOTA_IOS_SIMULATOR` pin a runtime and a model, otherwise the newest available iOS runtime and, on
it, the first model in that script's preference list (iPhone 17 Pro downwards). The model and the
runtime change what the auditor reports, so the choice is declared rather than whatever `simctl`
listed first. `QUOTA_IOS_TEXT_SIZE` (SwiftUI `DynamicTypeSize` name or a
`UICTContentSizeCategory*` value) and `QUOTA_IOS_APPEARANCE` (`light` or `dark`) are forwarded to
the UI tests; variant runs write a subdirectory. Every UI test launch names its text size — the
profile's, else the standard `large` — and launches with the in-app Appearance preference at System,
so neither the simulator's last setting nor a saved preference changes what a run draws. The
`ios-screens` job reports its runner allocation wait (queued → started) separately from its
execution time. Screenshot artifacts are for local
visual QA; `ios-screens` captures the same class in CI, advisory.

### DEBUG visual fixtures

DEBUG builds accept launch arguments that load offline UI state for screenshots (no network or
Keychain restore). Scenarios live under `Sources/Fixtures/`: a small `VisualScenario` value, shared
content builders in `VisualFixtureContent`, and blocked network / memory stores in
`FixtureServices`.

```bash
# Example scheme arguments:
#   --visual-fixture content
#   --visual-fixture content --route usage.patterns
#   --visual-fixture content --visual-clock wall
# Values: signed-out | connecting | connect-error | expired | confirm-account | connect-refresh-failed | loading | content | cached-error | empty | no-devices | local-only | merged | providers | activity-loading | activity-failed | activity-day-empty | activity-day-failed | sign-in | sign-in-methods
```

`--route` opens a destination on that scenario without tapping through: `usage`, `usage.today`,
`usage.custom` (the fixed range August 8 – 12, 2026: six through two UTC days before the fixture
clock), `usage.breakdown`, `usage.patterns`, `usage.day`, `subscription.detail/<key>`, `settings`,
`settings.devices`, `settings.notifications`, `settings.appearance`, `settings.about`. The default
display clock is `VisualFixture.referenceDate` so period titles and activity days agree;
`--visual-clock wall` keeps today's clock for marketing captures.

To add a scenario: add a `VisualFixture` case, a `VisualScenario.make` branch (phase, session,
summary, usage, local readings), content in `VisualFixtureContent` if the data is new, and its
launch string in the parser test's table. The state test walks every case and refuses a scenario
that goes online or that `VisualScenario.validationIssues` rejects, so a combination the scenario
must hold goes there, not in a test that restates the scenario's contents. A census test for a single screen goes in
`QuotaScreenUITests` and passes `--route` (add a route rather than tap through to a second screen); a journey or an interaction contract goes in
`QuotaSmokeUITests`, which is the required check, so add there only what a merge must not break.

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
`github.run_number`. The owner (not CI on an unsigned pull request) creates the tag. main already
carries the version to tag: once an `ios-vX.Y.Z` upload succeeds, the workflow's `bump-next` job
opens `chore/bump-ios-X.Y.(Z+1)` as the repository's automation GitHub App and lets it auto-merge,
the way `release-menubar` does (see `AGENTS.md`, Development commands). A suffixed prerelease tag
spends no version, and a minor or major is the exception — close the bot's pull request and run
`pnpm version:bump:ios minor` by hand.

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
