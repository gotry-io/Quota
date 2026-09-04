# Quota iOS Design

This file is the canonical visual and interaction specification for the native iOS Quota app and its
WidgetKit surfaces. Website marketing UI belongs in `apps/web/DESIGN.md`. QuotaBar's menu panel
belongs in `apps/menubar/DESIGN.md`.

## Product character

Quota on iPhone is a native iOS 26 read-only Account instrument: remaining quota first, Today Usage
second, collection/setup and account-management support third. Liquid Glass belongs to the system
navigation and control layer. Quota data, settings rows, status text, meters, charts, and
empty-state explanations are content and do not use glass. It is not a compressed website and not
the QuotaBar menu panel.

Core rules:

1. Remaining quota is the primary value. Today tokens and API-equivalent cost support it.
2. Connect with GitHub and Log Out are the only account actions this device performs. Delete Account
   starts on the website after a fresh GitHub sign-in.
3. Last-good Account data stays visible across transient failures. A status line states that in
   words, not color alone.
4. Views render typed `packages/apple-client` results. They never show tokens, opaque session
   material, raw JSON, or device identifiers.
5. Every control is VoiceOver labelled and usable with Dynamic Type, Reduce Motion, Reduce
   Transparency, and light or dark appearance. System controls handle Reduce Transparency; the app
   does not simulate transparency.
6. Widgets render only the non-secret App Group snapshot. They never authenticate, call Relay, or
   invent a second data path.

## Shared product vocabulary

Freshness copy, reset copy, the one no-reset phrase, provider display names, quota window titles, period names, and Devices copy follow
**Shared product vocabulary** in [`../menubar/DESIGN.md`](../menubar/DESIGN.md); the exact strings
and thresholds are `packages/protocol/fixtures/freshness-copy-conformance.json`, which
`packages/apple-shared` answers in its tests. The app and its widgets compose those phrases through
`FreshnessCopy` and never assemble their own. Local remaining-quota alerts answer
`packages/protocol/fixtures/alert-transition-conformance.json`; both Apple apps evaluate that file
through `QuotaAlerts`.

## Surfaces

```text
Connect with GitHub
TabView
  Overview
  Usage
  Devices
  Settings
Widget overview (small, medium, large, circular, rectangular, inline)
```

Signed-out Connect is presented directly, without an empty NavigationStack. Signed-in tabs use the
iOS 26 `Tab` initializer and `tabBarMinimizeBehavior(.onScrollDown)`. There is no root backdrop.

### Connect Account

Shown when no Keychain account session exists, including after logout and after an expired refresh,
and while a session is still `pending` (issued but not confirmed).

The Keychain record is one session with `activation: pending | active`. `completeLogin` writes
`pending`. A pending session may fetch the identifying Account summary. `restore()` of a pending
session returns to this confirmation flow (or its first-refresh failure state) and never to the
signed-in tabs. **Continue** is the only promotion of that same session to `active`. **Use a
different account** and Log Out revoke and clear either state.

- A 56-point Quota app mark, shared with confirmation. It is content, not glass. The glyph fills
  the 56-point frame.
- Primary action **Connect with GitHub**. Connecting: **Connecting…** with an inline ProgressView,
  disabled. Minimum hit height 50pt. Idle uses `buttonStyle(.glassProminent)` and the emerald tint.
  Connecting uses neutral system `.glass` with explicit label-color foreground so the spinner and
  **Connecting…** stay readable. The accessibility label stays **Connect with GitHub**; the value
  is **Connecting** and the control is not actionable.
- Footnote: **This iPhone only reads data reported by QuotaBar.**
- No product title, value-proposition paragraph, card, banner container, or raw URL.
- The longer product and privacy explanation lives on Settings › About, not on Connect.
- Only exceptional state copy appears under the footnote as a plain Label with an SF Symbol:
  - expired: **Session expired. Connect again.**
  - connect failure default: **Couldn't connect. Try again.**

Connect with GitHub starts `ASWebAuthenticationSession` for the Relay authorize URL with
`prefersEphemeralWebBrowserSession = false`, so the sheet shares Safari cookies. GitHub can reuse
an account already signed in in Safari; the session lives in the system browser, not in the app.
The system sheet owns cancel and is the connecting progress presentation. Cancellation returns to
the normal signed-out state without an error. The app never embeds a web view.

After Relay issues a session the first Account refresh must succeed and name a non-blank
`summary.account.displayLabel` before confirmation is constructed. The app does not open the
signed-in tabs. It replaces Connect content on the same signed-out screen:

- The 56-point Quota app mark (the same view Connect uses).
- Title **Use this GitHub account?** (`title2` semibold).
- Body **Connected as `<label>`.** with the label in bold.
- Primary **Continue** (`glassProminent`, system accent, no extra `.tint`) — promotes the pending
  session to `active` and enters the signed-in tabs.
- Secondary **Use a different account** (`.bordered`) — revokes the session just opened and starts
  Connect with GitHub again with `prefersEphemeralWebBrowserSession = true` so GitHub presents a
  login page. That second success confirms the same way.

If that first refresh fails, the session stays `pending`. Connect is replaced by **Retry** (repeats
the identifying read) and **Use a different account**. Continue is not shown, and the app does not
invent a generic **Account** identity. A 401 or expired result revokes the pending session and
shows the expired connect copy.

There is no sheet, card, `presentationDetents`, or `glassEffect` on the title or body. Layout is a
vertically centered, scroll-safe column with a maximum content width of 320 points and system
safe-area padding. Hit targets stay at least 44pt (Connect, Retry, and Continue 50pt).

Connect failures use a specific sentence when one is known, otherwise the default retry:

| Cause | Copy |
| --- | --- |
| Unexpected callback (`state` mismatch, missing code, token in the callback) | **The browser returned an unexpected response. Try again.** |
| Network (`unavailable` / timeout) | **Could not reach quota.gotry.io.** |
| Relay 4xx (`invalid_grant`, unauthorized, expired grant) | **The sign-in expired before it finished. Try again.** |
| Malformed summary or blank `displayLabel` | **Couldn't connect. Try again.** |
| Anything else | **Couldn't connect. Try again.** |

### Overview

Shown when an `active` session exists. Content comes from the last complete Account summary, then from a
refresh of Today. An inset-grouped `List`. Pull to refresh runs one Today fetch. A fetch in flight
ignores additional refresh requests.

Header:

- Title is the account display label, or **Account** when the label is absent. The body does not
  repeat that label.

Body, in order:

1. Status row, when a refresh or cached-data message exists: a plain `StatusMessage` Label on a
   standard list-row background. Cached: **Showing saved data. Couldn't refresh.** No cache:
   **Couldn't refresh. Pull to try again.** Keep provider-state and freshness vocabulary from the
   shared formatters unchanged.
2. Quota. Each subscription is one standard `NavigationLink` row (`ProviderQuotaRow`): provider
   name, masked account label, optional neutral plan capsule, and `QuotaWindowBlock` children. The
   List row background is the only content container. Remaining is the strongest number, with one
   meter per percent window and reset copy. A reading that is not current names why in place of, or
   ahead of, that reset time, because the reset it names may already have passed: **Sign-in
   needed**, **Unavailable**, **Unsupported**, or **Can’t refresh** for a state its device
   reported, and **Not current** for one that aged past its `valid_until`. Widgets apply the same
   rule at the instant they draw. Remaining has no "left" or "remaining" suffix. Budget windows
   with an amount use `71% · $3.75`, percent-only windows use `71%`, and balance-only windows use
   **Balance** plus the unit amount. Empty windows: **No quota windows yet.** The canonical
   **Updated** age is the quota Section footer; it wraps and is spoken in full.
3. If there are no subscriptions: `ContentUnavailableView` titled **No quota yet**, system image
   `gauge.with.dots.needle.33percent`, description **Set up QuotaBar on a Mac to start reporting.**
4. Today, before setup or device support: Tokens, API-equivalent cost, Input, and Output, with
   monospaced values. Complete cost is `$X.XX`, partial is `≥ $X.XX`, unavailable is **— unpriced**.
   Empty: **No usage today.**
5. When `summary.devices` is empty, the compact Mac setup Section after Today. When devices exist,
   Overview does not repeat the Devices list; the Devices tab is the one full device list.

Glance hierarchy follows the same information order as the Nowdex-inspired widgets (remaining first,
then provider/window, then support ages). Do not copy Nowdex assets or layout chrome.

### Subscription detail

Opened from an Overview quota row, and from `io.gotry.quota:/subscriptions/<selection_id>` when
that id matches a current subscription. An unmatched selection stays on Overview. The system back
button is the only way back; there is no second close control.

The title is the provider display name. An inset-grouped `List`:

- Identity: `LabeledContent` rows **Account** and, when present, **Plan** as plain text. Canonical
  freshness is the Section footer.
- Quota: one `QuotaWindowBlock` per window as native rows. Remaining is the strongest text. Empty:
  **No quota windows yet.**
- Readings: one native row per source. Leading column is display name, primary remaining, then
  freshness; trailing text is **Reporting** only on the selected source. Empty: **No device
  readings yet.**

A window still in the future by less than a day uses a live countdown (`Text(timerInterval:)`). A
later reset uses the shared reset copy. A reset that has already passed prints no Resets line.

Each device row is that device's display name (or **Device** when the name is missing), the primary
remaining figure from that source, and freshness. The page never shows a device id, fingerprint,
subscription key, or a custom surface. There is no independent loading or error state on this
pushed view; it renders the selected last-good subscription.

### Widget overview

Widgets use the information hierarchy inspired by Nowdex: strongest remaining label first, then
provider and window, then reset and updated age. Do not copy Nowdex assets or layout chrome.

Families:

| Family | Content |
| --- | --- |
| systemSmall | Primary (most constrained, or the configured subscription) item: remaining, provider, window, reset/updated age |
| systemMedium | Up to two most constrained items, compact Today tokens and cost, and **Updated** age |
| systemLarge | Up to six items as a list: provider · window, remaining, meter, countdown |
| accessoryCircular | Percent windows use an `accessoryCircular` Gauge ring; balance-only shows the amount |
| accessoryRectangular | Primary remaining, provider · window, optional reset age |
| accessoryInline | `<Provider> <remaining>%` |

Widgets are configurable through `AppIntentConfiguration`. The parameter is an optional
subscription (`nil` is **Automatic**: the most constrained subscription in the snapshot). Each
`AppEntity` id is the item's `selection_id`; its display name is `providerDisplayName · windowTitle`
from that snapshot item and never an account label. Candidates come from the App Group snapshot.
A configured `selection_id` the snapshot no longer carries falls back to Automatic; small and
medium still draw the ranked items and never show an error.

Shared rules:

- Format with `RemainingQuotaFormat`, `CompactCountFormat`, `UsageCostFormat`,
  `CompactAgeFormat`, and `FreshnessCopy`. Digits are monospaced. Semantic text styles and colors
  only.
- Mark the strongest remaining value with `widgetAccentable()`.
- Use `containerBackground(for: .widget)`. Do not call `glassEffect`. The system owns widget
  Liquid Glass, accented, and vibrant rendering inside that container.
- A future reset under 24 hours uses `Text(timerInterval:countsDown:)` so the system ticks seconds
  without a new timeline entry. Otherwise the line is static `FreshnessCopy.resetCopy`. A reset
  instant at or before the entry date prints no Resets line.
- Each item's `widgetURL` is `io.gotry.quota:/subscriptions/<selection_id>`. A medium or large
  widget with more than one item keeps `io.gotry.quota:/overview` for the widget as a whole; a
  large row is a `Link` to that row's subscription.
- Placeholder is a redacted/skeleton overview. Missing, corrupt, or oversize snapshot files show
  safe **No data yet** copy. Timelines refresh about every fifteen minutes so ages advance; the
  extension never fetches. The app republishes the snapshot on a foreground refresh and on a
  background app refresh it asks for no sooner than every thirty minutes.

### Usage

Shown when a session exists. Period totals come from the same Account summary as Overview: the four
precomputed periods `today`, `last_7_days`, `last_30_days`, and `all`. Opening Usage requests the
last 365 UTC days of activity once (`from = today-364`, `to = today`) and keeps that answer in
memory; it does not write it to disk. A failure stays in the Activity card and does not block the
period list.

Header:

- Title is **Usage**.

Body, in order:

1. A segmented period control: **Today**, **7 Days**, **30 Days**, and **2 Years**. The fourth
   segment's VoiceOver name is **Up to 2 years**. Default is **30 Days**. The selection lives in
   memory for the signed-in session.
2. Headline card: Tokens as the strongest number (`CompactCountFormat`) with an `in · out` support
   line, then API-equivalent cost (`$X.XX`, `≥ $X.XX`, or **— unpriced**). When `partial` is true,
   a footnote: **Some hours in this period were scanned incompletely.**
3. Activity card: a Sunday-first heatmap of those 365 UTC days. Columns are weeks, rows are
   weekdays, the chart scrolls horizontally and opens on today (the trailing edge). Fill is five
   steps over tokens — empty, then four equal bands of the busiest day in the response, the same
   mapping the website uses. Today has a primary stroke. Loading is a skeleton in the card;
   failure is **Could not load activity.** with **Retry**.
4. Agent groups in the summary's order. Each agent uses its display name (Codex, Claude Code, Grok,
   OpenCode, Pi, Cursor). Inside an agent, provider subheadings (`InferenceProvider.displayName`)
   and model rows (display name · tokens · cost). The model `other` is **Other**. Each provider
   shows at most five models until **Show N more** reveals the rest.
5. When the selected period has no agents: **No Usage in this period.** The Activity card still
   shows.

Each model row is one VoiceOver element that reads the model, tokens, and cost. Rows wrap at
accessibility text sizes. The heatmap is one adjustable control: VoiceOver reads the selected day
as date, tokens, and cost, swiping adjusts the day, and activating opens that day. Individual cells
are not accessibility elements.

Tapping a cell, or activating the heatmap, presents a sheet for that UTC day: the long UTC date,
tokens, API-equivalent cost and its basis, and **Some hours on this day were scanned incompletely.**
when `partial` is true. The sheet then asks `detail=agents` for that date. Loading is a skeleton;
failure is **Could not load this day's usage.** with **Retry**; an empty agent tree is **No Usage on
this day.**; a populated tree reuses the period's agent groups.

### Devices

An inset-grouped `List` of the Account's collection devices. Do not repeat **Devices** inside the
body. Each row is display name, an **Active** / **Idle** / **Not reporting** verdict, platform, and
the last-reading age that verdict came from. Use text as well as any symbol; color cannot carry the
verdict. VoiceOver speaks name, verdict, platform, and age. Never infer failure from sleep,
shutdown, or a closed app, and never show raw Device IDs or request a remote Device's credentials.

A top-trailing system toolbar `Link` uses the `arrow.up.right` symbol. Visible and accessibility
label: **Manage Devices on Web**. Destination is `https://quota.gotry.io/my`. The toolbar supplies
its own Liquid Glass.

Empty state is `ContentUnavailableView`: title **No Macs connected**, image `desktopcomputer`,
description **Install QuotaBar on a Mac signed in with this GitHub account.**, action **Download
QuotaBar**. No QR code or custom surface. Root loading covers summary loading. Device status is
last-good account content.

### Settings

A native `Form` hub with the system content background. Notification thresholds, appearance, and
About are pushed destinations that share `SettingsModel`. Account actions sit on this hub so they
are reachable without scrolling through alert groups. Every control is a standard Form toggle,
picker, link, or button. Settings has no custom loading state.

**Preferences.** NavigationLink **Notifications**. NavigationLink **Appearance** with the current
value **System**, **Light**, or **Dark** trailing.

**Privacy & Support.** Link **Privacy** (`https://quota.gotry.io/privacy`). Link **Support**
(`https://quota.gotry.io/support`). NavigationLink **About**.

**Account.** Link **Manage Devices on Web** (`https://quota.gotry.io/my/devices`). **Delete
Account…** explains that deletion happens on the website after a fresh GitHub sign-in, then opens
`ASWebAuthenticationSession` (shared Safari cookies, not ephemeral) at
`https://quota.gotry.io/api/auth/github/start?return_to=%2Fmy%2Fsettings%3Fdelete%3Daccount`. The
callback scheme is nil: the sheet ending returns to the app. Quota then prompts **If you deleted
the Account, sign out here too.** **Log Out** keeps the native confirmation: remote Account data
remains; this device forgets the session.

#### Notifications

Navigation title **Notifications**. Native Form. Toggle **Enable Notifications**. Toggle **Reset
Reminders**. Footer: **Alerts are checked when Quota refreshes.** Quota does not promise real-time.

Turning Enable Notifications on asks `UNUserNotificationCenter` for alerts and sound. A refusal
puts the switch back off and shows **Allow notifications for Quota in Settings.** with **Open
Settings**, which opens `UIApplication.openSettingsURLString`. Opening the destination re-reads
the system permission; a later grant in Settings does not turn the switch on by itself. A
permission-refresh failure leaves the toggle off and uses the denied-state rows. Rules are stored
in `UserDefaults` under `alerts.*`.

One Section per subscription (catalog `display_name` as the header, masked account label as a row)
with two remaining-percent pickers **Alert at** and **Then at**. Choices are **5 / 10 / 15 / 20 /
25 / 30 / 40 / 50**. The first defaults to **20**; the second defaults to **10** and may be **Off**,
which stores a single threshold. Stored values stay descending and unique, and the second picker
only offers values below the first. If there are no subscriptions, **No quota alerts are available
yet.** appears below the master controls.

#### Appearance

Navigation title **Appearance**. A native inline Picker with **System**, **Light**, and **Dark**.
Stored as `appearance` in `UserDefaults`. The window uses `.preferredColorScheme`. System is the
default and leaves the scheme unset. No custom preview panel or glass.

#### About

Navigation title **About**. The Quota app mark as plain content, then:

- **Quota shows remaining quota and usage reported by QuotaBar on your Mac.**
- **This iPhone does not collect or upload local usage.**

Native rows **Version** (`CFBundleShortVersionString (CFBundleVersion)`), **Website**
(`https://quota.gotry.io`), **GitHub** (the repository), and **License** with value **MIT**. No
glass card. Links are standard Form links.

### Mac setup

Shown when `summary.devices` is empty. Title **Set up QuotaBar**. Detail: **Install QuotaBar on a
Mac signed in with this GitHub account.** Destination is `https://quota.gotry.io/download`. On
Overview the action is a standard `Link` row **Download for Mac**. On the Devices empty state it is
the `ContentUnavailableView` action **Download QuotaBar**. Neither receives glass inside a List.
There is no QR code and no raw URL text.

### Deep links

`io.gotry.quota:/overview` opens Overview. `io.gotry.quota:/subscriptions/<selection_id>` records the
selection, opens Overview, and pushes the matching subscription detail when the Account summary can
name it. An unmatched or unknown id stays on Overview. `selection_id` is twelve lowercase hex digits
after percent-decoding. Any other URL returns to Overview.

### Notification delivery

Quota on iOS evaluates the same local remaining-quota rules QuotaBar does, through `QuotaAlerts`,
and posts the same `AlertCopy` title and body. A successful refresh — pull-to-refresh or the
background app refresh asked for no sooner than every thirty minutes — compares the new Account
summary to the last available readings and delivers native `UNUserNotificationCenter` alerts.

A calendar notification is booked at each available subscription's primary window `resets_at` so a
reset is not missed if the next background refresh lands later. A later reading replaces the
previous request for that window. Signing out, or turning the rules off, removes every pending
reminder. A `windowReset` the evaluator emits for a window that already has a reminder is left to
that reminder.

Notification permission is requested from Settings › Notifications; an add while unauthorized is
silently ineffective.

## Liquid Glass (main app)

Quota is iOS 26-only. It uses Apple's native SwiftUI glass APIs on system navigation and controls.
There is no third-party UI kit, no custom glass shader, and no app-owned glass on content.

| Surface | Treatment |
| --- | --- |
| Tab bar | System `Tab` chrome; `tabBarMinimizeBehavior(.onScrollDown)` |
| Navigation / toolbar | System navigation chrome |
| Connect with GitHub | `.glassProminent` with emerald tint |
| Confirm Continue | `.glassProminent` with the system accent; no extra `.tint` |
| Sheets | System sheet chrome |
| Quota data, status, meters, charts, settings rows, empty states | Content. List/Form/Section grouping. No `glassEffect`. |

Rules:

1. Do not put an explicit glass effect inside another system glass control.
2. Do not reproduce system materials with gradients, strokes, shadows, custom blur, or rounded
   glass panels. There is no `quotaSurface`, ambient backdrop, or card token.
3. Reduce Transparency is owned by system glass. The app does not simulate transparency.
4. Widgets never call `glassEffect`; system widget chrome owns that rendering.

## States

| State | Presentation |
| --- | --- |
| Loading, no cache | Centered progress and **Loading account…**. No surface. |
| Empty quota | **No quota yet** with **Set up QuotaBar on a Mac to start reporting.** |
| Empty Today | **No usage today.** |
| Empty Usage period | **No Usage in this period.** |
| Loading activity | Skeleton in the Activity card |
| Activity failed | **Could not load activity.** with **Retry** |
| Empty activity day | **No Usage on this day.** |
| Device quiet or never heard from | **Idle** / **Not reporting** beside its age, or `no readings yet` |
| Offline or failed refresh, cache present | Last-good content plus **Showing saved data. Couldn't refresh.** |
| Offline or failed refresh, no cache | Empty Overview plus **Couldn't refresh. Pull to try again.** |
| Expired session | Connect with GitHub plus **Session expired. Connect again.** |
| Connect running | One disabled **Connecting…** button with visible progress. No status line. |
| Connect failure | Connect with GitHub plus one plain status Label. Default **Couldn't connect. Try again.** |
| Confirm GitHub account | Same signed-out screen: mark, **Use this GitHub account?**, **Connected as `<label>`.**, **Continue**, **Use a different account**. No sheet. |
| Notification permission denied | **Allow notifications for Quota in Settings.** with **Open Settings** |
| No quota alerts | **No quota alerts are available yet.** below the Notifications master controls |
| Widget no-data | **No data yet** (or accessory em dash); no error chrome |
| Widget placeholder | Redacted remaining / provider skeleton |

A status line is a plain wrapping `StatusMessage` Label with a symbol and a sentence. Color never
carries status alone. There is no status card or glass.

## Layout and type

Signed-in tabs use the system grouped background supplied by List/Form. Overview, subscription
detail, and Devices are inset-grouped Lists. There is no root background modifier and no ambient
wash. Settings is a compact hub Form; Notifications, Appearance, and About are pushed destination
Forms with the same system background. Semantic text styles (`largeTitle` / `title2` for remaining
values, `headline` for provider names, `subheadline` and `footnote` for support). Connect content is
a 320-point column. `ProviderQuotaRow` and `QuotaWindowBlock` are content only: no padding, corner,
stroke, shadow, material, or glass of their own.

Spacing uses 8, 12, 16, and 24pt. Hit targets stay at least 44pt (Connect with GitHub 50pt). Dynamic
Type may wrap every label, including the Connect footnote; do not clip remaining values.
Accessibility text sizes and widget no-data layouts must keep the strongest remaining figure
readable (`minimumScaleFactor` is preferred over truncation of the primary value).

The accent is adaptive emerald (`#087456` light, `#82ddb8` dark). Ink, body, and mute follow
`Color.primary` / `Color.secondary` / tertiary label. Critical red is only for Log Out, Delete Account, their
confirmations, and unrecoverable failure copy.

Widgets stay denser: `title2` / `title3` / `headline` for remaining, `subheadline` / `caption` for
provider and support, and no custom card chrome beyond the system widget container.

## Accessibility

- Icon-only controls have accessibility labels.
- The Connect mark is one static element named **Quota**. The button's accessibility label is
  exactly **Connect with GitHub**; its hint is **Opens GitHub sign-in in your browser.** While
  connecting, the value is **Connecting** and the control does not respond to interaction.
- Remaining meters expose the remaining percent and window title, not only a graphic.
- Cost states include the words **complete**, **partial**, or **unpriced**.
- The Overview quota Section footer is the shared freshness phrase, read in full.
- Each Devices row is one VoiceOver element that speaks name, verdict, platform, and age.
- Overview subscription rows keep the hint **Opens subscription details**.
- The Usage heatmap is one adjustable element. It speaks the selected UTC date, tokens, and cost;
  cells are not their own VoiceOver nodes.
- Widget entries combine provider, remaining, why the reading is not current, reset, and updated
  age into one label, in the order the entry shows them.
- Do not announce raw account, device, or token identifiers.
- Reduce Motion uses opacity-only transitions for Connect ↔ Overview phase changes. The root
  phase replacement is an explicit `.opacity` transition; Reduce Motion only shortens it.
- Reduce Transparency is system-owned. Do not skip Connect's contrast audit in the signed-out
  or connecting state. Confirm is inline on the signed-out screen and runs the full accessibility
  audit with no skip.
- Settings account actions sit on the hub, not below per-subscription alert groups. Settings
  destinations run the full app-owned accessibility audit. Do not skip an unnamed clipping issue.
  System exceptions, scoped in the UI test: unnamed tab-bar Liquid Glass contrast, grouped Form
  header/footer StaticText contrast, and partial Dynamic Type on system section-header text.
  Connect (no tab bar) still runs contrast.

## Visual QA

Inspect Connect with GitHub (mark, button, and footnote only in the normal state), connecting,
connect error, expired session, the inline GitHub account confirmation, loading, signed-in
Overview (quota first, Today second, system NavigationLink chevron, no device-summary
duplication, no content glass), empty quota/Today, no-devices Mac setup without a QR code or raw
URL, cached content with a plain status Label, subscription detail (Account, Plan, Quota, Readings),
Devices content and empty, Usage at 30 Days with the Activity heatmap, a single-day sheet, the four
tabs, Settings hub (Notifications and Appearance links, Log Out, Delete Account), Settings ›
Notifications, Settings › Appearance, Settings › About, and each widget family in placeholder,
content, and no-data states. Check iPhone, light and dark, standard and accessibility text sizes,
VoiceOver labels, Reduce Motion, and Reduce Transparency. Synthetic fixtures may contain display
labels only; they must never contain access tokens, refresh tokens, or production data.

`scripts/ios-ui-screenshots.sh` exports the `overview-content`, `overview-cached-error`,
`overview-no-devices`, `connect-signed-out`, `connect-connecting`, `connect-error`,
`connect-expired`, `connect-refresh-failed`, `root-loading`, `confirm-account`, `usage-content`,
`usage-activity`, `subscription-detail`, `devices-content`, `devices-empty`, `settings-main`,
`settings-notifications`, `settings-appearance`, and `settings-about` fixture screenshots to
`dist/ios-ui-screenshots/`.

### DEBUG visual fixtures

For deterministic simulator screenshots (DEBUG builds only), pass a launch argument:

```text
--visual-fixture signed-out
--visual-fixture connecting
--visual-fixture connect-error
--visual-fixture expired
--visual-fixture confirm-account
--visual-fixture connect-refresh-failed
--visual-fixture loading
--visual-fixture content
--visual-fixture cached-error
--visual-fixture empty
--visual-fixture no-devices
```

| Fixture | UI state |
| --- | --- |
| `signed-out` | Connect with GitHub: mark, button, and footnote. No session restore |
| `connecting` | Disabled **Connecting…** button with visible progress on neutral glass |
| `connect-error` | Connect with GitHub plus **Couldn't connect. Try again.** |
| `expired` | Connect with GitHub plus **Session expired. Connect again.** |
| `connect-refresh-failed` | Pending session after a failed first refresh: **Retry**, **Use a different account**, **Could not reach quota.gotry.io.** No Continue |
| `confirm-account` | Inline signed-out confirmation for **octocat**: mark, **Use this GitHub account?**, **Continue**, **Use a different account** |
| `loading` | Centered **Loading account…** |
| `content` | Signed-in Overview with synthetic Codex / Claude / Grok windows and Today values. Codex reports from two devices so subscription detail can show per-device readings; Usage has four periods with increasing totals, one provider group of more than five models, and an in-memory Activity heatmap of the last 365 UTC days |
| `cached-error` | Same content plus **Showing saved data. Couldn't refresh.** |
| `empty` | Signed-in Overview with empty quota and **No usage today.** Usage of every period is **No Usage in this period.** |
| `no-devices` | Signed-in Overview with no devices and no subscriptions (compact Mac setup Section) |

Fixtures construct `AppModel` UI state in-process, skip Keychain/network restore, and never embed
access tokens, refresh tokens, or production data. Release builds ignore the flag. Launch-time
fixtures anchor synthetic timestamps to the process launch instant so Updated age and reset
instants stay current; unit tests inject `VisualFixture.referenceDate` for determinism.
