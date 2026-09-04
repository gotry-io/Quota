# Quota iOS Design

This file is the canonical visual and interaction specification for the native iOS Quota app and its
WidgetKit surfaces. Website marketing UI belongs in `apps/web/DESIGN.md`. QuotaBar's menu panel
belongs in `apps/menubar/DESIGN.md`.

## Product character

Quota on iPhone is a read-only Account instrument: remaining quota first, Today Usage
second, GitHub identity as context. It uses native SwiftUI, system materials, and a restrained
emerald accent. It is not a compressed website and not the QuotaBar menu panel.

Core rules:

1. Remaining quota is the primary value. Today tokens and API-equivalent cost support it.
2. Connect Account and Log Out are the only account actions this device performs. Delete Account
   starts on the website after a fresh GitHub sign-in.
3. Last-good Account data stays visible across transient failures. A banner states that in words,
   not color alone.
4. Views render typed `packages/apple-client` results. They never show tokens, opaque session
   material, raw JSON, or device identifiers.
5. Every control is VoiceOver labelled and usable with Dynamic Type, Reduce Motion, and light or
   dark appearance.
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
Connect Account
TabView
  Overview
  Usage
  Devices
  Settings
Widget overview (small, medium, large, circular, rectangular, inline)
```

### Connect Account

Shown when no Keychain account session exists, including after logout and after an expired refresh.

- Product name **Quota**.
- One sentence: **See remaining quota and Today Usage for the GitHub Account you use with QuotaBar on
  your Mac.**
- Primary action **Connect Account**.
- Quiet note that this device does not collect or upload local usage.
- Optional status line after an expired session: **Session expired. Connect Account to continue.**

Connect Account starts `ASWebAuthenticationSession` for the Relay authorize URL with
`prefersEphemeralWebBrowserSession = false`, so the sheet shares Safari cookies. GitHub can reuse
an account already signed in in Safari; the session lives in the system browser, not in the app.
The system sheet owns cancel. The app never embeds a web view.

After Relay issues a session and the first Account refresh names `summary.account.displayLabel`,
the app does not open the signed-in tabs. It shows a full-screen confirmation:

- Title **Use this GitHub account?**
- Body **Connected as `<label>`.** with the label in bold.
- Primary **Continue** — enters the signed-in tabs.
- Secondary **Use a different account** — revokes the session just opened and starts Connect
  Account again with `prefersEphemeralWebBrowserSession = true` so GitHub presents a login page.
  That second success confirms the same way.

Layout is a calm centered instrument: compact Quota mark, value proposition, privacy note, and the
primary action inside one semantic surface. Status banners (connecting, failure, expired) sit
inside that panel. Hit targets stay at least 44pt.

Connect Account failures use a specific sentence, not a generic retry:

| Cause | Copy |
| --- | --- |
| Unexpected callback (`state` mismatch, missing code, token in the callback) | **The browser returned an unexpected response. Try again.** |
| Network (`unavailable` / timeout) | **Could not reach quota.gotry.io.** |
| Relay 4xx (`invalid_grant`, unauthorized, expired grant) | **The sign-in expired before it finished. Try again.** |
| Anything else | **Could not connect this account. Try again.** |

### Overview

Shown when a session exists. Content comes from the last complete Account summary, then from a
refresh of Today.

Header:

- Title is the account display label, or **Account** when the label is absent.

Body, in order:

1. Banner, when needed.
2. Account context: display label plus the shared freshness line (`Updated 15m ago`). Standard
   Dynamic Type keeps a single-line horizontal row; accessibility sizes stack label and age
   vertically with full wrapping (no one-line ellipsis). VoiceOver reads the full label and the
   same line.
3. Provider quota cards in catalog order, one card per subscription. Each observation shows
   provider name, optional account label and plan, remaining value as the strongest number, one
   meter per percent window, and reset time. The whole card opens subscription detail. A reading
   that is not current names why in place of, or ahead of, that reset time, because the reset it
   names may already have passed: **Sign-in needed**, **Unavailable**, **Unsupported**, or **Can’t
   refresh** for a state its device reported, and **Not current** for one that aged past its
   `valid_until`. Widgets apply the same rule at the instant they draw. Remaining has no "left" or
   "remaining" suffix. Budget windows with an amount use `71% · $3.75`, percent-only windows use
   `71%`, and balance-only windows use **Balance** plus the unit amount.
4. Devices: when `summary.devices` is empty, the Mac setup card. When it has devices, a compact
   summary of display names and **Active** / **Idle** / **Not reporting** verdicts. The full list
   lives on the Devices tab.
5. Today: tokens and API-equivalent cost as the headline — the same one QuotaBar and the website
   show — then input and output as supporting detail. Complete cost is `$X.XX`, partial is
   `≥ $X.XX`, unavailable is **— unpriced**.

Pull to refresh runs one Today fetch. A fetch in flight ignores additional refresh requests.

Glance hierarchy follows the same information order as the Nowdex-inspired widgets (remaining first,
then provider/window, then support ages). Do not copy Nowdex assets or layout chrome.

### Subscription detail

Opened from an Overview quota card, and from `io.gotry.quota:/subscriptions/<selection_id>` when
that id matches a current subscription. An unmatched selection stays on Overview.

The title is the provider display name. The body is the masked account label and plan, the shared
freshness line, each window's remaining value, meter, and reset countdown, then one row per
reporting device.

A window still in the future by less than a day uses a live countdown (`Text(timerInterval:)`). A
later reset uses the shared reset copy. A reset that has already passed prints no Resets line.

Each device row is that device's display name (or **Device** when the name is missing), the primary
remaining figure from that source, and freshness. The source whose reading is the one on the card
is marked **Reporting**. The page never shows a device id, fingerprint, or subscription key.

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
- Use `containerBackground(for: .widget)`. Do not call `glassEffect`. On iOS 26 the system owns
  widget Liquid Glass, accented, and vibrant rendering inside that container; on iOS 17–25 the
  system material fallback applies.
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

The Account's collection devices: display name, an **Active** / **Idle** / **Not reporting**
verdict, and one line of platform plus the age that verdict came from. Never infer failure from
sleep, shutdown, or a closed app, and never show raw Device IDs or request a remote Device's
credentials. Empty state shows the Mac setup card rather than hiding the section. A trailing
**Manage devices on the web** link opens `https://quota.gotry.io/my`.

### Settings

A native `Form` of grouped rows. Every control is a standard Form toggle, picker, link, or button.

**Notifications.** A master switch, **Reset reminders**, and one group per subscription (catalog
`display_name` as the header, masked account label as a row) with two remaining-percent pickers.
Choices are **5 / 10 / 15 / 20 / 25 / 30 / 40 / 50**. The first defaults to **20**; the second
defaults to **10** and may be **Off**, which stores a single threshold. Stored values stay
descending and unique, and the second picker only offers values below the first. Turning the master
switch on asks `UNUserNotificationCenter` for alerts and sound. A refusal puts the switch back off
and shows **Allow notifications for Quota in Settings.** with **Open Settings**, which opens
`UIApplication.openSettingsURLString`. Opening the page re-reads the system permission; a later
grant in Settings does not turn the switch on by itself. Rules are stored in `UserDefaults` under
`alerts.*`. The group footer is **Quota reminds you when a refresh brings new data.** Quota does
not promise real-time.

**Appearance.** **System**, **Light**, or **Dark**, stored as `appearance` in `UserDefaults`. The
window uses `.preferredColorScheme`. System is the default and leaves the scheme unset.

**About.** Version is `CFBundleShortVersionString (CFBundleVersion)`. Links to
`https://quota.gotry.io` and the GitHub repository. **Licenses: MIT**.

**Privacy & Support.** Links to `https://quota.gotry.io/privacy` and
`https://quota.gotry.io/support`.

**Account.** **Manage devices on the web** opens `https://quota.gotry.io/my/devices`. **Delete
Account…** explains that deletion happens on the website after a fresh GitHub sign-in, then opens
`ASWebAuthenticationSession` (shared Safari cookies, not ephemeral) at
`https://quota.gotry.io/api/auth/github/start?return_to=%2Fmy%2Fsettings%3Fdelete%3Daccount`. The
callback scheme is nil: the sheet ending returns to the app. Quota then prompts **If you deleted
the Account, sign out here too.** **Log Out** keeps the native confirmation: remote Account data
remains; this device forgets the session.

### Mac setup

Shown on Overview and Devices when `summary.devices` is empty. Title **Set up a Mac**. One sentence:
**Quota shows what QuotaBar on your Mac reports. Install it on a Mac signed in with the same GitHub
account.** A `Link` to `https://quota.gotry.io/download` and a QR code generated locally with
CoreImage `CIQRCodeGenerator` for that same URL. No network.

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

Quota on iOS 26 uses Apple's native SwiftUI glass APIs. There is no third-party UI kit and no custom
glass shader.

Progressive behavior:

| Surface | iOS 26 | iOS 17–25 |
| --- | --- | --- |
| Semantic cards, banners, Connect panel | `glassEffect(.regular, in: continuous 16pt shape)` | `.regularMaterial` in the same continuous shape |
| Primary button | `.glassProminent` with emerald tint | `.borderedProminent` with emerald tint |
| Navigation / toolbar | System navigation chrome | System navigation chrome |
| Tab bar | System TabView | System TabView |

Rules:

1. One glass/material surface per semantic card. Nested rows, meters, and plan chips stay plain.
2. An ambient Quota backdrop (semantic grouped fill plus a restrained emerald wash, light and dark)
   sits behind content so glass and material read clearly.
3. Surface and button modifiers live in `QuotaTheme` (`quotaSurface`, `quotaProminentButtonStyle`).
   Views do not invent alternate corner radii or fills.
4. Widgets never call `glassEffect`; system widget chrome owns that rendering.

## States

| State | Presentation |
| --- | --- |
| Loading, no cache | Centered progress and **Loading account…** |
| Empty quota | **No quota reported yet.** Collection happens on a Mac running QuotaBar that is signed into this Account. |
| Empty Today | **No Usage for Today.** |
| Empty Usage period | **No Usage in this period.** |
| Loading activity | Skeleton in the Activity card |
| Activity failed | **Could not load activity.** with **Retry** |
| Empty activity day | **No Usage on this day.** |
| Device quiet or never heard from | **Idle** / **Not reporting** beside its age, or `no readings yet` |
| Offline or failed refresh, cache present | Last-good content plus **Showing saved account data. Could not refresh.** |
| Offline or failed refresh, no cache | Empty Overview plus **Could not refresh account data. Pull to try again.** |
| Expired session | Connect Account with **Session expired. Connect Account to continue.** |
| Connect running | Connect Account with **Continue in the browser.** |
| Confirm GitHub account | Full-screen **Use this GitHub account?** with **Continue** and **Use a different account** |
| Widget no-data | **No data yet** (or accessory em dash); no error chrome |
| Widget placeholder | Redacted remaining / provider skeleton |

A banner always includes a symbol and a sentence. Color never carries status alone.

## Layout and type

Use the system grouped background (under the ambient wash) and semantic text styles (`largeTitle` /
`title2` for remaining values, `headline` for provider names, `subheadline` and `footnote` for
support). Cards are continuous 16pt corners. Content has a readable measure: 20pt horizontal gutter
and a maximum 720pt column.

Spacing uses 8, 12, 16, and 24pt. Hit targets stay at least 44pt. Dynamic Type may wrap every
label; do not clip remaining values. Accessibility text sizes and widget no-data layouts must keep
the strongest remaining figure readable (`minimumScaleFactor` is preferred over truncation of the
primary value).

The accent is adaptive emerald (`#087456` light, `#82ddb8` dark). Ink, body, and mute follow
`Color.primary` / `Color.secondary` / tertiary label. Critical red is only for Log Out, Delete Account, their
confirmations, and unrecoverable failure copy.

Widgets stay denser: `title2` / `title3` / `headline` for remaining, `subheadline` / `caption` for
provider and support, and no custom card chrome beyond the system widget container.

## Accessibility

- Icon-only controls have accessibility labels.
- Remaining meters expose the remaining percent and window title, not only a graphic.
- Cost states include the words **complete**, **partial**, or **unpriced**.
- The account context line is the shared freshness phrase, read in full.
- The Usage heatmap is one adjustable element. It speaks the selected UTC date, tokens, and cost;
  cells are not their own VoiceOver nodes.
- Widget entries combine provider, remaining, why the reading is not current, reset, and updated
  age into one label, in the order the entry shows them.
- Do not announce raw account, device, or token identifiers.
- Reduce Motion uses opacity-only transitions for Connect ↔ Overview phase changes.

## Visual QA

Inspect Connect Account, the GitHub account confirmation, loading, signed-in content, empty quota/Today, Usage at 30 Days with the
Activity heatmap, a single-day sheet, no-devices Mac setup, cached content with a refresh banner,
expired session, the four tabs, Settings (Notifications switch, Log Out, Appearance), subscription
detail (windows, countdown, Reporting row), and each widget family in placeholder, content, and
no-data states. Check iPhone, light and dark, standard and accessibility text sizes, VoiceOver
labels, and Reduce Motion. Synthetic fixtures may contain display labels only; they must never
contain access tokens, refresh tokens, or production data.

`scripts/ios-ui-screenshots.sh` exports the `content`, `signed-out`, `confirm-account`,
`no-devices`, `usage-content`, `usage-activity`, `subscription-detail`, and `settings` fixture
screenshots to `dist/ios-ui-screenshots/`.

### DEBUG visual fixtures

For deterministic simulator screenshots (DEBUG builds only), pass a launch argument:

```text
--visual-fixture signed-out
--visual-fixture confirm-account
--visual-fixture content
--visual-fixture cached-error
--visual-fixture empty
--visual-fixture no-devices
```

| Fixture | UI state |
| --- | --- |
| `signed-out` | Connect Account, no session restore |
| `confirm-account` | Full-screen **Use this GitHub account?** for **octocat**, with **Continue** and **Use a different account** |
| `content` | Signed-in Overview with synthetic Codex / Claude / Grok windows and Today values. Codex reports from two devices so subscription detail can show per-device readings; Usage has four periods with increasing totals, one provider group of more than five models, and an in-memory Activity heatmap of the last 365 UTC days |
| `cached-error` | Same content plus **Showing saved account data. Could not refresh.** |
| `empty` | Signed-in Overview with empty quota and **No Usage for Today.** Usage of every period is **No Usage in this period.** |
| `no-devices` | Signed-in Overview with no devices and no subscriptions (Mac setup card) |

Fixtures construct `AppModel` UI state in-process, skip Keychain/network restore, and never embed
access tokens, refresh tokens, or production data. Release builds ignore the flag. Launch-time
fixtures anchor synthetic timestamps to the process launch instant so Updated age and reset
instants stay current; unit tests inject `VisualFixture.referenceDate` for determinism.
