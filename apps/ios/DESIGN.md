# Quota iOS Design

This file is the canonical visual and interaction specification for the native iOS Quota app and its
WidgetKit surfaces. Website marketing UI belongs in `apps/web/DESIGN.md`. QuotaBar's menu panel
belongs in `apps/menubar/DESIGN.md`.

## Product character

Quota on iPhone is a native iOS 26 quota instrument: remaining quota first, Today Usage second,
collection/setup and account-management support third. It reads the providers it is signed in to on
this device and, when there is a Quota account, what QuotaBar reports from the Macs; Overview is
those merged, not two lists. Liquid Glass belongs to the system navigation and control layer. Quota data, settings rows, status text, meters, charts, and
empty-state explanations are content and do not use glass. It is not a compressed website and not
the QuotaBar menu panel.

Core rules:

1. Remaining quota is the primary value. Today tokens and API-equivalent cost support it.
2. Connect with GitHub, Continue with Apple, and Log Out are the only account actions this device
   performs. Delete Account starts on the website after a fresh sign-in. Signing in is an
   invitation inside the app, never a wall in front of it: without an account the tabs still
   open on whatever this phone read for itself.
3. Last-good Account data stays visible across transient failures. A status line states that in
   words, not color alone.
8. Views render typed `packages/apple-client` results. They never show tokens, opaque session
   material, raw JSON, or device identifiers.
5. Every control is VoiceOver labelled and usable with Dynamic Type, Reduce Motion, Reduce
   Transparency, and light or dark appearance. System controls handle Reduce Transparency; the app
   does not simulate transparency.
6. Widgets render only the non-secret App Group snapshot. They never authenticate, call Relay, or
   invent a second data path.

## Shared product vocabulary

Freshness copy, reset copy, the one no-reset phrase, the pace line, provider display names, quota window titles, period names, and Devices copy follow
**Shared product vocabulary** in [`../menubar/DESIGN.md`](../menubar/DESIGN.md); the exact strings
and thresholds are `packages/protocol/fixtures/freshness-copy-conformance.json`, reset copy is
`packages/protocol/fixtures/reset-copy-conformance.json`, and remaining copy is
`packages/protocol/fixtures/remaining-copy-conformance.json`, which
`packages/apple-shared` answers in its tests. The app and its widgets compose those phrases through
`FreshnessCopy` and `RemainingQuotaFormat` and never assemble their own. A window's pace prints under its support line in
`QuotaTheme.warning` when the rate runs the window out before it resets and in secondary otherwise;
there is no Rust on iOS, so the app derives it with `QuotaPace` from the reading it already holds,
answering `packages/protocol/fixtures/quota-pace-conformance.json`. Widgets show no pace: the space
belongs to the number. Local remaining-quota alerts answer
`packages/protocol/fixtures/alert-transition-conformance.json`; both Apple apps evaluate that file
through `QuotaAlerts`, including the pace warning Settings can turn off.

## Surfaces

```text
TabView (always; a sign-in in flight takes the screen)
  Overview
  Usage
  Devices
  Settings
Widget overview (small, medium, large, circular, rectangular, inline)
```

The tabs are the app. Connect takes the whole screen only while a sign-in is in flight —
`connecting`, the pending-confirmation screen, and a pending session whose first read failed —
because those are questions waiting for an answer. A phone that is simply signed out shows the
tabs, and the Overview empty state carries both invitations. **Sign in to Quota**, wherever it is
offered, presents the sign-in page as a sheet over what is already on screen; nothing opens until a
way in is chosen there. Connect is presented directly, without an empty NavigationStack. Tabs use the iOS 26 `Tab` initializer and
`tabBarMinimizeBehavior(.onScrollDown)`. There is no root backdrop.

### Connect Account

The sign-in page, presented as a sheet from every **Sign in to Quota** invitation, and the whole
screen while a sign-in is in flight or a `pending` session's first read has failed.

The Keychain record is one session with `activation: pending | active`. `completeLogin` writes
`pending`. A pending session may fetch the identifying Account summary. `restore()` of a pending
session returns to this confirmation flow (or its first-refresh failure state) and never to the
signed-in tabs. **Continue** is the only promotion of that same session to `active`. **Use a
different account** and Log Out revoke and clear either state.

- A 56-point Quota app mark, shared with confirmation. It is content, not glass. The glyph fills
  the 56-point frame.
- Three ways in, 12pt apart, in the order every Quota surface lists them — Apple, GitHub, Email.
  Each is 50pt tall.
- **Continue with Apple**: `SignInWithAppleButton(.continue)`, Apple's own control drawn by Apple,
  capsule-clipped to match, black in light appearance and white in dark as Apple's guidelines pair
  them. Its label, mark, and sheet are Apple's; the app draws no substitute glyph and adds no tint.
- **Continue with GitHub** (`buttonStyle(.glassProminent)`, emerald tint) and **Continue with
  Email** (neutral system `.glass`, explicit label-color foreground). Both open the same Relay
  authorize URL, because that is one round trip: Relay's `/sign-in` page is what asks which Account
  this is and offers every channel that reaches one
  ([ADR 0032](../../docs/decisions/0032-an-account-owns-its-identities.md)). Their accessibility
  hint is **Opens Quota sign-in in your browser.**
- While a sign-in is in flight the three are replaced by one disabled control, `connect.connecting`:
  **Connecting…** with an inline ProgressView on neutral `.glass`. Its accessibility label is
  **Connecting** and it is not actionable. Which channel opened the browser is not something the
  app knows once the sheet is up — the page asks — so the busy label names none of them, and
  Apple's control, which has no busy presentation of its own, is not drawn then rather than shown
  disabled.
- Footnote: **This iPhone only reads data reported by QuotaBar.**
- No product title, value-proposition paragraph, card, banner container, or raw URL.
- The longer product and privacy explanation lives on Settings › About, not on Connect.
- Only exceptional state copy appears under the footnote as a plain Label with an SF Symbol:
  - expired: **Session expired. Connect again.**
  - connect failure default: **Couldn't connect. Try again.**

Continue with Apple asks on the device instead: `ASAuthorizationAppleIDProvider` requests the full
name and email scopes and a nonce, and the identity token it returns is posted straight to Relay,
which answers with the same `pending` session a browser sign-in opens. There is no browser sheet and
no `return_to`. Cancelling at Apple returns to the normal signed-out state without an error; any
other failure shows the connect-failure copy. Confirmation, Retry, and Use a different account are
the same screens either way.

The browser channels start `ASWebAuthenticationSession` for the Relay authorize URL with
`prefersEphemeralWebBrowserSession = false`, so the sheet shares Safari cookies. GitHub can reuse
an account already signed in in Safari; the session lives in the system browser, not in the app.
The system sheet owns cancel and is the connecting progress presentation. Cancellation returns to
the normal signed-out state without an error. The app never embeds a web view.

Email finishes somewhere else. The link Relay mails is opened by the mail app, so the navigation
that proves the address runs in the system browser rather than inside the authentication session,
and Relay's redirect to `io.gotry.quota:/oauth/callback` arrives as a URL open. The app exchanges
that code against the attempt it is still holding, then ends the sheet that is waiting for a
callback it will never see — so cancel there is not a sign-out. The attempt is held in memory
alone: a relaunch while the person is in their mail app leaves no verifier to spend, and the app
says **Couldn't connect. Try again.** rather than pretending it can finish.

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
| Network (`unavailable` / timeout) | **Couldn't reach quota.gotry.io.** |
| Relay 4xx (`invalid_grant`, unauthorized, expired grant) | **The sign-in expired before it finished. Try again.** |
| Malformed summary or blank `displayLabel` | **Couldn't connect. Try again.** |
| Anything else | **Couldn't connect. Try again.** |

### Overview

Always shown behind the tab bar. Its content is one merged list, whichever sides answered:

| Sources | What Overview shows |
| --- | --- |
| Only this iPhone | Title **Quota**. Quota rows from what this phone read. No Today section, because Today is the Account's fold and this phone uploads nothing. |
| Only the Account | Title is the account label. Quota rows from `subscriptions[]`, plus Today. Unchanged from before. |
| Both | One row per subscription, merged by [ADR 0003](../../docs/decisions/0003-observation-preserving-subscription-merge.md) — an account both a Mac and this phone read is one row, and a tie goes to this phone because it is the authority for the device in front of you. Today is still the Account's. |

Content comes from the last complete Account summary and the last local collection, then from a
refresh of both. An inset-grouped `List`. Pull to refresh runs the local pass and, with an account,
one Today fetch. A refresh in flight ignores additional refresh requests.

Header:

- Title is the account display label, or **Account** when the label is absent. The body does not
  repeat that label.

Body, in order:

1. Status row, when a refresh or cached-data message exists: a plain `StatusMessage` Label on a
   standard list-row background. Cached: **Showing saved data. Couldn't refresh.** No cache:
   **Couldn't refresh. Pull to try again.** Keep provider-state and freshness vocabulary from the
   shared formatters unchanged.
2. Sync-off row, when the Account read carries an `entitlement` that is not `active` or `grace`:
   a tappable `StatusMessage` with `arrow.trianglehead.2.clockwise.rotate.90` and a trailing
   chevron, reading **Sync is off. Subscribe to see your Macs here.** It presents the paywall as
   a sheet with **Done**. The sentence is the one Relay's own 402 `subscription_required` is
   spoken as, so a refused write and this row never disagree.
3. Quota. Each subscription is one standard `NavigationLink` row (`ProviderQuotaRow`): provider
   name with an 8pt incident dot after the name when this device's last-good status-page reading
   is `minor` or worse (VoiceOver speaks the status-page description; there is no tooltip),
   masked account label, optional neutral plan capsule, and `QuotaWindowBlock` children. The
   List row background is the only content container. Status pages are fetched on this device
   (`QuotaProviderStatus`); Relay does not forward them. Widgets do not show the mark. Remaining
   is the strongest number, with one meter per percent window and reset copy. A reading that is
   not current names why in place of, or ahead of, that reset time, because the reset it names
   may already have passed: **Sign-in needed**, **Unavailable**, **Unsupported**, or **Can’t
   refresh** for a state its device reported, and **Not current** for one that aged past its
   `valid_until`. Widgets apply the same rule at the instant they draw. Remaining has no "left"
   or "remaining" suffix. Budget windows with an amount use `71% · $3.75`, percent-only windows
   use `71%`, and balance-only windows use **Balance** plus the unit amount. Empty windows: **No
   quota windows yet.** The canonical
   **Updated** age is the quota Section footer; it wraps and is spoken in full.
4. If there are no subscriptions: `ContentUnavailableView` titled **No quota yet**, system image
   `gauge.with.dots.needle.33percent`, and the two ways to change that as buttons. Without an
   account the description is **Connect a provider to read your quota on this iPhone, or sign in to
   Quota to see what your Macs report.** with **Connect a provider** (switches to Settings, where
   the Providers group is) and **Sign in to Quota**. With one it is **Set up QuotaBar on a Mac to
   start reporting, or connect a provider to read it on this iPhone.** and only **Connect a
   provider**.
5. Today, only when an account answered, before setup or device support: Tokens, API-equivalent
   cost, Input, and Output, with monospaced values. Complete cost is `$X.XX`, partial is `≥ $X.XX`, unavailable is **— unpriced**.
   Empty: **No usage today.**
6. When `summary.devices` is empty, the compact Mac setup Section after Today. When devices exist,
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
- Today: one native row per window of the reading's own cadence that the reader's day already
  holds — the local clock times it ran between, and its peak used percent — with the Section footer
  naming the day in one line, **Today: 3 windows · 82% / 40% / 12%**. The section is absent unless
  this phone read the subscription itself.
- Readings: one native row per source. Leading column is display name, primary remaining, then
  freshness; trailing text is **Reporting** only on the selected source. Empty: **No device
  readings yet.**

A window still in the future by less than a day uses a live countdown (`Text(timerInterval:)`). A
later reset uses the shared reset copy. A reset that has already passed prints no Resets line.

A window this phone has read more than once draws a 44pt pace line above its reset row: solid over
the samples it took inside the running window, dashed from the last of them to where the ADR 0035
projection lands at the reset, with the vertical axis the whole window from 0 to 100 percent used.
Only a reading this phone took itself gets one — a reading Relay resolved was taken by some Mac,
which keeps its own samples and never sends them — and the same rule governs the Today section. The
fold is `packages/protocol/fixtures/quota-history-conformance.json`, answered here by
`QuotaHistory`; samples are kept 30 days in the app's own container and are never uploaded
([ADR 0042](../../docs/decisions/0042-quota-history-is-local-samples.md)). Widgets draw no line:
the space belongs to the number.

Each device row is that device's display name — **This iPhone** for what this device read itself,
or **Device** when a name is missing — the primary remaining figure from that source, and
freshness. The page never shows a device id, fingerprint, subscription key, or a custom surface. There is no independent loading or error state on this
pushed view; it renders the selected last-good subscription.

### Widget overview

Widgets use the information hierarchy inspired by Nowdex: strongest remaining label first, then
provider and window, then reset and updated age. Do not copy Nowdex assets or layout chrome.
Home Screen families show remaining quota. Lock Screen accessory families show the Weekly
window's used percent (`100 − remaining`) plus **Resets in …**.

Families:

| Family | Content |
| --- | --- |
| systemSmall | One subscription (most constrained, or the configured one): provider, two windows shortest-cadence first, remaining, reset, **Updated** age |
| systemMedium | Up to three providers, one row each (most constrained window, remaining, meter, reset). A configured subscription shows that subscription's windows instead. Compact Today tokens and cost, and **Updated** age |
| systemLarge | Up to three providers × two windows: remaining, meter, countdown, then Today tokens/cost and **Updated** age |
| accessoryCircular | Weekly used percent in an `accessoryCircularCapacity` Gauge ring; balance-only shows the amount |
| accessoryRectangular | Three stacked lines: Weekly used percent, its **Resets in …**, then the subscription's second window with its own reset |
| accessoryInline | `Weekly <used>% · Resets in …` |

A window whose snapshot carries `pace` `runs_out` uses the system orange warning color for its
remaining or used figure. No pace means no extra color. The extension never derives pace.

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
- A meter is a `linearCapacity` Gauge over the remaining percent, tinted `.secondary`. A row is
  text, not a link: a medium or large row's `Link` is tinted `.primary` so the hierarchical text
  styles inside it do not resolve against the accent color.
- The Lock Screen families are narrow. Neither the circular ring's window title nor a second
  column of reset copy fits, so those lines stack instead of sitting side by side.
- Use `containerBackground(for: .widget)`. Do not call `glassEffect`. The system owns widget
  Liquid Glass, accented, and vibrant rendering inside that container.
- A future reset under 24 hours uses `Text(timerInterval:countsDown:)` so the system ticks seconds
  without a new timeline entry. Otherwise the line is static `FreshnessCopy.resetCopy`. A reset
  instant at or before the entry date prints no Resets line.
- Each item's `widgetURL` is `io.gotry.quota:/subscriptions/<selection_id>`. A widget whose
  visible rows share one `selection_id` opens that subscription. Several subscriptions keep
  `io.gotry.quota:/overview` for the widget as a whole; a medium or large row is a `Link` to
  that row's subscription. Small and Lock Screen families are one tap target — the whole widget
  opens its `widgetURL`, and no row is a `Link` there.
- Placeholder is a redacted/skeleton overview. Xcode previews cover content, no-data, and
  placeholder for every supported family (small, medium, large, circular, rectangular, inline).
  Inspect standard, accented, and vibrant rendering in those previews; do not encode those
  rendering modes in app logic. Missing, corrupt, or oversize snapshot files show safe **No data
  yet** copy. Timelines refresh about every fifteen minutes so ages advance; the extension never
  fetches. The app republishes the snapshot on a foreground refresh and on a background app
  refresh it asks for no sooner than every thirty minutes.

### Usage

Shown when a session exists. One inset-grouped `List` is the scrolling hierarchy. Four periods —
`today`, `last_7_days`, `last_30_days`, `all` — come precomputed from the same Account summary as
Overview. Every other period is added up on this iPhone from the activity days it already holds,
which is why it has totals and cost but no model breakdown. Opening Usage requests the last 365 UTC
days of activity once (`from = today-364`, `to = today`) and keeps that answer in memory; it does
not write it to disk. A failure stays in the Activity section and does not block the period totals
or model sections, but it does leave a folded period and the budget bar with nothing to add up.

Header:

- Title is **Usage**.

Body, in order:

1. A segmented period control in the first List row: **Day**, **Week**, **Month**, **7D**, **30D**,
   and **All**, whose VoiceOver names are the full ones in Shared product vocabulary. Default is
   **Last 30 days**. A custom range selects none of the six, so the control shows nothing selected.
   The selection lives in memory for the signed-in session. It is a system content filter, not a
   floating navigation action, and it scrolls with the List.
2. A stepper row under it: a **Previous period** chevron, the range the period covers, a **Next
   period** chevron, and a calendar button. Stepping applies to Day, Week, and Month only, and the
   current unit is the last, so both chevrons are disabled on a fixed window and **Next period** is
   disabled on the current one. The calendar button opens a **Custom range** sheet of two
   `DatePicker`s bounded by the activity range, with **Cancel** and **Apply**.
3. A **Monthly budget** section: a `ProgressView` and one monospaced-digit line of
   `spent / budget · percent` for this month, or **No budget is set for this month.**, then a
   **Set budget** / **Edit budget** row opening a sheet with the amount in USD and a **Tell me at
   80% and 100%** toggle. Both fields are `UserDefaults` on this iPhone and are never uploaded.
   The two crossings post one local notification each per calendar month.
4. Totals section: `LabeledContent` rows for **Tokens** (`CompactCountFormat`, monospaced),
   **API-equivalent cost** (`$X.XX`, `≥ $X.XX`, or **— unpriced**), **Cache hit** (whole percent, or
   **—** for a period with no input), and **Reasoning** (tokens of output). Supporting copy in that
   section is `{input} in · {output} out`, then one line `{cost-basis} · Priced N of M rows`
   from that period's cost row counts (the priced sentence shares the cost-basis row so later
   List sections stay on screen), `Cache hit {percent} · saved $X.XX`
   when the period's cache reads could be priced, and **Some hours in this period were scanned
   incompletely.** when `partial` is true. Cache hit and its saving follow
   [ADR 0036](../../docs/decisions/0036-usage-derived-metrics.md). No custom card. Semantic text
   styles, primary color, so contrast and Dynamic Type stay system-owned. A period this iPhone
   added up itself carries no cache saving, so that line is absent there.
5. When the period was added up here rather than read from the summary, one line saying so, in
   place of the model sections: the breakdown is on Today, Last 7 days, Last 30 days, and All.
6. When the selected period has no agent sections: `ContentUnavailableView` titled **No usage**,
   system image `chart.bar`, description **No usage was reported for this period.** The Activity
   section still follows.
6a. Daily section, headed **Daily**, for any period but All and only when those days reported
   something. It covers the days the period covers, bounded by the activity days this phone holds.
   A segmented **Tokens** / **Cost** control decides what the bars measure; in Tokens the
   bar stacks cached input, fresh input, and output, which add up to the day's total, and in Cost it
   is one fill. The bars are `Color.primary` at 25% / 55% / 90%, and a day with nothing in it is
   drawn at 12% rather than left out. A **Daily breakdown** `DisclosureGroup` under them lists the
   days newest first, each as `date` / `tokens · cost` with `in · out · cached · reasoning ·
   messages` beneath. The section footer names the calendar: **UTC days.** The All period has no
   Daily section, and neither has any period a Rhythm — Relay stores hours on UTC keys and does not
   fold a local clock, so the hour-of-day view is QuotaBar's alone
   ([ADR 0036](../../docs/decisions/0036-usage-derived-metrics.md)).
7. Activity section, headed **Activity**:
   - Loading: the redacted grid skeleton as plain section content. Accessibility value **Loading
     activity**.
   - Failure: **Couldn't load activity.** plus a native **Retry** row.
   - Loaded with zero reported tokens across the range: **No activity in the last year.** Do not
     render 365 empty interactive cells.
   - Loaded with data: a Sunday-first heatmap of those 365 UTC days. Columns are weeks, rows are
     weekdays, the chart scrolls horizontally and opens on today (the trailing edge). Fill is five
     emerald steps over tokens — empty, then four equal bands of the busiest day in the response,
     the same mapping the website uses. Today has a primary stroke. Weekday and month labels use
     `caption` / `caption2`. Month abbreviations are never truncated to an ellipsis, including a
     last month that occupies only one week. Cells are visual shapes, not buttons. The grid is one
     adjustable control: a spatial tap or drag selects the nearest in-range day; VoiceOver
     increment/decrement changes the same selection. Under the grid, the selected day is visible
     text (long UTC date, tokens, cost) followed by a 44-point **View day** button that presents
     that day.
7a. Top models section, headed **Top models**, when the period has more than one model leaf: the
   three largest, each as `{share} · {tokens}`.
8. Each agent is a Section headed by its display name (Codex, Claude Code, Grok, OpenCode, Pi,
   Cursor). Provider names are subhead rows (`InferenceProvider.displayName`) ending in that
   provider's whole-percent share of the period, with a 4pt share bar under them; models are
   standard rows with the model name leading and `{tokens} · {cost} · {share}` trailing. The model `other` is
   **Other**. Each provider shows at most five models until **Show N more** reveals the rest;
   **Show fewer** collapses them again. Both are standard 44-point List buttons with expanded /
   collapsed accessibility state.

Each model row is one VoiceOver element that reads the model, tokens, and cost. Rows wrap at
accessibility text sizes. Individual heatmap cells are not accessibility elements. The combined
chart value remains date, tokens, and cost.

**View day** presents a `NavigationStack` sheet for the selected UTC day: the long UTC date as the
inline title, system **Done** as the confirmation toolbar item, `presentationDetents` medium and
large, and the system drag indicator. The body is an inset-grouped List of totals and agent
Sections — the same rows as the period view, including **Some hours on this day were scanned
incompletely.** when `partial` is true. Loading text: **Loading this day's usage…**. Failure:
**Couldn't load this day's usage.** with **Retry**. Empty: **No usage on this day.** The sheet
asks `detail=agents` for that date. There is no custom material.

### Devices

The Account's list, so without an account it is one `ContentUnavailableView`: title **Sign in to
see your Macs**, image `desktopcomputer`, description **Quota lists the Macs reporting to your
account. This iPhone reads the providers you connect here whether or not you sign in.**, action
**Sign in to Quota**. The Manage Devices toolbar link is absent then, and so is the This iPhone row:
there is no list for it to end.

With an account, an inset-grouped `List` of the Account's collection devices, then **This iPhone**
as the last row — platform **iOS**, verdict and age from the last local collection. It is not an
Account Device and carries no Manage or Remove control; what it reads is removed by removing a
provider sign-in in Settings. Do not repeat **Devices** inside the body. Each row is display name,
an **Active** / **Idle** / **Not reporting** verdict, platform, and the last-reading age that
verdict came from. Use text as well as any symbol; color cannot carry the
verdict. VoiceOver speaks name, verdict, platform, and age. Never infer failure from sleep,
shutdown, or a closed app, and never show raw Device IDs or request a remote Device's credentials.

A top-trailing system toolbar `Link` uses the `arrow.up.right` symbol. Visible and accessibility
label: **Manage Devices on Web**. Destination is `https://quota.gotry.io/my/devices`, the same
URL Settings uses. The toolbar supplies its own Liquid Glass.

An account with no Macs is `ContentUnavailableView`: title **No Macs connected**, image
`desktopcomputer`, description **Install QuotaBar on a Mac signed in with this GitHub account.**,
action **Download QuotaBar** — with the This iPhone row still beneath it. No QR code or custom
surface. Root loading covers summary loading. Device status is last-good account content.

### Settings

A native `Form` hub with the system content background. Notification thresholds, appearance, and
About are pushed destinations that share `SettingsModel`. Account actions sit on this hub so they
are reachable without scrolling through alert groups. Every control is a standard Form toggle,
picker, link, or button. Settings has no custom loading state.

**Sync.** The first group, and the only place a subscription is bought or read. Without one —
`entitlement.status` of `expired`, `none`, or a member this build cannot name — one NavigationLink
**Sync across devices** to the paywall. With one, a `LabeledContent` **Sync** whose value is the
state Relay reports, and a Link **Manage** to `https://apps.apple.com/account/subscriptions`; the
system owns cancelling and changing a plan and Quota does not reimplement it. Footer: **Sync is
billed through the App Store and managed in your Apple Account.**

Status values are derived from the Relay entitlement, never from the store SDK on the device:
`active` and renewing is **Active · renews `<date>`**, `active` and not renewing is
**Expires `<date>`**, `active` without an expiry is **Active**, and `grace` is **Grace period**.

**Preferences.** NavigationLink **Notifications**. NavigationLink **Appearance** with the current
value **System**, **Light**, or **Dark** trailing.

**Providers.** One row per provider account this iPhone signed in to, then the row that adds
another. A provider with nothing connected shows only that row, trailing **Connect**; a provider
that already has an account shows **Add Account** instead, because a second account of one provider
is a second row rather than a replacement. A connected row is the catalog `display_name`, then
**Connected as <masked label>** and **Checked <age> ago** in footnote rows — primary foreground, as
a Devices row does, because `.secondary` at that size does not clear this app's contrast bar — with
a trailing **Remove**. When the last local collection was refused for that session, the second line
is **Sign in again to keep reading this account.** and a **Sign in again** control precedes Remove:
only a fresh sign-in fixes a refused cookie, so the row says that instead of an age that will never
move. A provider that could not be reached leaves the row alone. That button is standard, not red:
the system destructive red on a Form row does not clear this app's contrast bar, and what is
destructive about it is said by the confirmation it opens, whose **Remove** is the destructive one.
Remove confirms in a native dialog — **Remove this <Provider> sign-in?** — and says the
cookies are deleted from this iPhone's Keychain and that Quota stops reading that provider here.
The footer is **Sign-in cookies stay in this iPhone's Keychain. Quota never uploads them, and
Remove deletes them.**, replaced by **Couldn't read the sign-ins saved on this iPhone.** when the
Keychain refused the read — an empty list would say the opposite of what happened.

The first Connect for a provider shows one confirmation, **Sign in to <Provider>?**, naming that
provider's cookies and hosts from the catalog, that they stay in this iPhone's Keychain, that they
are never uploaded, and that Remove deletes them. **Continue** opens the sheet and is remembered
per provider; **Cancel** stores nothing. This is the iOS wording of the same paragraph as QuotaBar's
Browser Sign-in consent ([ADR 0010](../../docs/decisions/0010-provider-browser-session-auth.md),
[ADR 0034](../../docs/decisions/0034-ios-collects-for-itself.md)).

**Provider sign-in sheet.** A full-screen sheet titled **Sign in to <Provider>** with **Cancel** in
the leading toolbar slot, the provider's own sign-in page in a `WKWebView`, and one status line
under it: **Sign in to <Provider> to connect this account.**, then **Checking this session…**,
**Not signed in yet. Finish signing in on this page.**, **Couldn't reach <Provider>. Try again.**,
or **<Provider> doesn't report quota for this account.** A proven session closes the sheet and the
Providers row becomes **Connected as <masked label>**. The web view carries none of this app inside
it: no injected script, no read of page content, no intercepted form or navigation.

**Sign-in methods.** With an account, one row per channel an Account can be reached through, in
the order every Quota surface lists them: Apple, GitHub, Email. An Account owns its identities
rather than being one ([ADR 0032](../../docs/decisions/0032-an-account-owns-its-identities.md)),
so this is a group of channels, not one account name. Each row is the channel name in
`subheadline` medium over a footnote line — primary foreground, as a Providers row is — reading
the bound channel's label, **Linked** when it is bound with no label (Apple hands over an address
only while the person is sharing one), **Linking…** while a bind is in flight, or **Not linked**.

A channel that is not bound carries its own way to bind it. Apple's is
`SignInWithAppleButton(.continue)` at 132 × 36pt, drawn by Apple in the same pairing as the
sign-in page, because Apple asks on the device and no browser is involved: the token it signs is
posted to `POST /oauth/v2/apple` with `intent: link` under this device's session. GitHub and Email
carry **Link on Web**, which opens `https://quota.gotry.io/sign-in?return_to=%2Fmy%2Fsettings` in
`ASWebAuthenticationSession` with shared Safari cookies and a nil callback scheme; binding writes
to an Account, so the browser has to be signed in as one, and `/sign-in` is what asks which. The
group ends with **Manage on Web**, the same trip, which is also the only way to unbind: unbinding
is a destructive account change the website asks for a recent sign-in before allowing, and this
app does not hold a second copy of that rule. The rows are re-read when that sheet ends.

The list is `GET /api/v2/account`'s `identities[]`, read when Settings appears and again after any
bind. It is not cached: what may sign in to an Account is read when it is asked for. Footer:
**Bind another way in, or remove one, on the website. An Account keeps at least one.**, replaced by
**Couldn't read how you sign in to this Account.** when the read failed — an empty list would say
the opposite of what happened — or by the last bind's failure, **Couldn't add that way in. Try
again.** or **That Apple ID already belongs to another Quota account.** Cancelling at Apple leaves
the Account exactly as it was and says nothing.

**Privacy & Support.** Link **Privacy** (`https://quota.gotry.io/privacy`). Link **Support**
(`https://quota.gotry.io/support`). NavigationLink **About**.

**Account.** With an account: Link **Manage Devices on Web**
(`https://quota.gotry.io/my/devices`). **Delete Account…** explains that deletion happens on the website after signing in again, then
opens `ASWebAuthenticationSession` (shared Safari cookies, not ephemeral) at
`https://quota.gotry.io/sign-in?return_to=%2Fmy%2Fsettings%3Fdelete%3Daccount` — the page that
asks which Account this browser is, not one channel's round trip. The
callback scheme is nil: the sheet ending returns to the app. Quota then prompts **If you deleted
the Account, sign out here too.** **Log Out** keeps the native confirmation: remote Account data
remains; this device forgets the session and its saved overview, and keeps every provider sign-in.

Without an account the group is one button, **Sign in to Quota**, with the footer **Sign in to see
what QuotaBar reports from your Macs, and your usage across them.** There are no devices to manage
and nothing to delete, so those rows are absent rather than disabled.

#### Sync across devices

The paywall, pushed from Settings › Sync and presented as a sheet from the Overview sync-off row.
Quota draws it rather than rendering a remote RevenueCat Paywalls template, so its copy is
reviewed here, the offline fixtures can render it, and the accessibility audit covers it. An
inset-grouped `List`:

1. Headline **Sync across devices** and **Paid sync carries what your Macs collect to this iPhone,
   the website, and your widgets.**
2. Three checkmark `Label` benefits: **Every Mac you run QuotaBar on reports into one Account.**,
   **The website and your Home Screen widgets read that same account.**, **Usage history and a
   year of Activity are kept for you.**
3. Plans, one Button row per term with the price the store localized and the trial before it:
   **Monthly** and **Yearly**, detail **`<n>` days free, then `<price>`** or the price alone.
   Quota never composes a currency amount of its own.
4. **Restore Purchases**, Link **Terms** (`https://quota.gotry.io/terms`), Link **Privacy**, and
   the same billing footer as the Settings group.

A purchase the store accepts does not turn sync on by itself. The entitlement belongs to Relay,
which learns the purchase from a RevenueCat webhook, so the paywall says **Purchase complete.
Turning sync on…** and dismisses when the next Account read reports `active`. A build with no
RevenueCat API key states that in place of the plans: **Purchases unavailable in this build.**

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
| Continue with Apple | `SignInWithAppleButton`, `.black` in light appearance and `.white` in dark |
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
| Empty quota, with an account | **No quota yet** with **Set up QuotaBar on a Mac to start reporting, or connect a provider to read it on this iPhone.** and **Connect a provider** |
| Empty Today | **No usage today.** |
| Empty Usage period | `ContentUnavailableView` **No usage** / **No usage was reported for this period.** |
| Usage with no account | `ContentUnavailableView` **Sign in to see your usage** / **Usage is what QuotaBar reports from your Macs. This iPhone reads quota here, and measures no usage of its own.** with **Sign in to Quota** |
| Loading activity | Skeleton in the Activity section. Accessibility value **Loading activity** |
| Activity failed | **Couldn't load activity.** with **Retry** |
| Empty activity | **No activity in the last year.** |
| Loading activity day | **Loading this day's usage…** |
| Activity day failed | **Couldn't load this day's usage.** with **Retry** |
| Empty activity day | **No usage on this day.** |
| Device quiet or never heard from | **Idle** / **Not reporting** beside its age, or `no readings yet` |
| Offline or failed refresh, cache present | Last-good content plus **Showing saved data. Couldn't refresh.** |
| Offline or failed refresh, no cache | Empty Overview plus **Couldn't refresh. Pull to try again.** |
| Expired session | Overview status **Session expired. Connect again.** above whatever this phone still reads |
| Signed out, nothing read | **No quota yet** with **Connect a provider** and **Sign in to Quota** |
| Provider refused a stored session | That Providers row reads **Sign in again to keep reading this account.** with a **Sign in again** control |
| Connect running | One disabled **Connecting…** button with visible progress. No status line. |
| Connect failure | Overview status Label. Default **Couldn't connect. Try again.** |
| Confirm GitHub account | Same signed-out screen: mark, **Use this GitHub account?**, **Connected as `<label>`.**, **Continue**, **Use a different account**. No sheet. |
| Sync off | Overview sync-off row **Sync is off. Subscribe to see your Macs here.**, and Settings › Sync offering the paywall |
| Loading plans | **Loading plans…** with progress, accessibility value **Loading plans** |
| Plans failed | **Couldn't load subscription options.** with **Retry** |
| Purchase running | **Working…** with progress, plan rows disabled |
| Purchase made, Relay behind | **Purchase complete. Turning sync on…** |
| Purchase deferred | **Waiting for the App Store to confirm this purchase.** |
| Purchase failed | **Couldn't complete the purchase. Try again.** |
| Restore failed | **Couldn't restore purchases. Try again.** |
| No store in this build | **Purchases unavailable in this build.** |
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

Spacing uses 8, 12, 16, and 24pt. Hit targets stay at least 44pt (Connect with GitHub 50pt; Usage
**View day**, **Retry**, **Show N more**, and **Show fewer** are 44-point List rows). Dynamic Type
may wrap every label, including the Connect footnote, Usage period control, selected-day summary,
and model rows; do not clip remaining values. Heatmap cells stay 14-point shapes; weekday and
month labels on that grid use `caption` / `caption2`, keep the full month abbreviation, and cap
at `DynamicTypeSize.large` with the grid so they stay aligned at accessibility sizes.
Accessibility text sizes and widget no-data
layouts must keep the strongest remaining figure readable (`minimumScaleFactor` is preferred over
truncation of the primary value).

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
- The Usage heatmap is one adjustable element, not a button. It speaks the selected UTC date,
  tokens, and cost; cells are not their own VoiceOver nodes. Direct touch, VoiceOver adjust, and
  **View day** operate on the same selected date. **View day** is the 44-point activation that
  presents the day sheet. **Show N more** / **Show fewer** expose expanded or collapsed state.
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
  Connect (no tab bar) still runs contrast.
- Usage runs the same app-owned audit as the other screens, including contrast. Do not skip
  contrast, Dynamic Type, or clipping as whole audit types. Do not skip by `StaticText` type,
  "nearly passed", `"Resets "`, or List-button contrast. Documented system-owned exceptions,
  scoped to the named element:
  - unnamed tab-bar / navigation / sheet glass (`issue.element == nil`) for contrast, Dynamic
    Type, clipping, and inaccessible;
  - grouped List / Form section header and footer views whose accessibility identifier starts
    with `section.header.` or `section.footer.` (contrast and Dynamic Type). Those identifiers
    are: `section.header.today`, `section.header.quota`, `section.header.readings`,
    `section.header.activity`, `section.header.preferences`, `section.header.privacy-and-support`,
    `section.header.account`, `section.header.mac-setup`, `section.header.appearance`,
    `section.header.codex`, `section.header.claude_code`, `section.header.grok`,
    `section.header.opencode`, `section.header.pi`, `section.header.cursor`,
    `section.header.claude`, `section.footer.updated`, `section.footer.mac-setup`,
    `section.footer.account`, `section.footer.notifications`,
    `section.footer.subscription-updated`, `section.footer.usage.headline`,
    `section.footer.usage.day.headline`;
  - the system sheet **Done** confirmation button for Dynamic Type;
  - contrast and clipping on any element whose frame intersects the floating tab bar's frame
    (and contrast on any element whose frame intersects the floating navigation bar's frame once
    a list has scrolled under it; the same glass, at the other end of the screen);
  - contrast on an element that cannot be hit while a sheet's Done button is up: the presentation
    dims what is behind it, and that dimming is the system's;
  - contrast on `usage.activity.selected-day`: the date label shares its row container with the
    selected heatmap cell, whose accent ring the auditor reads as the label's background;
  - contrast on the `usage.top-model` rows by parent: the label colour on the row background, which
    iOS 26.3 passes and the 26.5 simulator reports as failing for the second row only — an
    exception to remove once that report reproduces
    (inset by 40 pt horizontally and 56 pt vertically): the Liquid Glass capsule and its bloom sit
    over the last visible rows, so the contrast auditor samples the glass, not the row, and the
    clipping auditor reads a covered row as cut off. This is geometric and system-owned; it never
    applies to rows away from the tab bar;
  - contrast, Dynamic Type, and clipping on the Today rows of Overview, scoped by frame containment
    to the elements this app marked `overview.today` or `overview.today.*`. Those rows are
    grouped-Form `LabeledContent`, so iOS 26 `UIListContentConfiguration` owns their colours, how
    much they grow, and how their label and value share the row, and the auditor names their inner label and value texts, which carry no identifier
    of their own — which is why matching the `overview.today` identifier on the reported element
    alone never reached them, and why the message on them reads "unsupported" rather than the
    "partially unsupported" the identifier-named rows below report. Containment in a marked row's
    frame is what ties a report back to a row: the exception is not by element type, not by how
    close the ratio came, and it is the only place either type is skipped by frame other than the
    tab-bar glass above;
  - iOS 26 `UIListContentConfiguration` List/Form Button, Link, and LabeledContent rows for the
    "Dynamic Type font sizes are partially unsupported" message only — they do not advertise
    full Dynamic Type. Contrast on those rows is not skipped, apart from the four Today rows the
    bullet above names by frame. Named identifiers:
    `usage.activity.retry`, `usage.activity.view-day`, `usage.day.retry`, `usage.show-more`,
    `usage.show-fewer`, `usage.daily.table`, `usage.headline`, `usage.day.headline`, `overview.today.tokens`,
    `overview.today.cost`, `overview.today.input`, `overview.today.output`,
    `overview.today.empty`, `subscription.account`, `subscription.plan`, `settings.about.version`,
    `settings.about.license`, `settings.notifications`, `settings.appearance`, `settings.about`,
    `overview.subscription`, `devices.manage`, `usage.activity.selected-day`,
    `usage.provider.<provider id>`, the totals-row labels **Tokens**, **API-equivalent cost**,
    **Cache hit**, and **Reasoning**, the Daily **Daily breakdown** disclosure label, the
    About **License** and **Version** labels, the
    Notifications **Enable Notifications** and **Reset Reminders** toggle rows, plus Link labels
    **GitHub**, **Website**, **Privacy**, **Support**, **Manage Devices on Web**, **Download for
    Mac**, **Download QuotaBar**.
- A contrast pass that exceeds the iOS 26 auditor deadline on the 365-day heatmap may retry
  without contrast; the run attaches which screen did not complete contrast. That is a deadline,
  not a type skip.
- The Connect footnote sits 24 pt below the prominent button so the button's glass bloom does not
  reach it.
- `scripts/ios-ui-screenshots.sh` removes its `/tmp/quota-ios-uitest-*` override files on exit; a
  stale text-size override would otherwise silently run every later UI test at that size.
- Overview and Usage UI tests scroll the list (`overview-scrolled`). Tab-bar minimization
  (`tabBarMinimizeBehavior(.onScrollDown)`) is a manual visual gate: the simulator used for
  screenshots does not expose a measurable height drop or a single-button minimized tab bar.

## Visual QA

Inspect Connect with GitHub and Continue with Apple (mark, both buttons, and footnote only in
the normal state), connecting,
connect error, expired session, the inline GitHub account confirmation, loading, signed-in
Overview (quota first, Today second, system NavigationLink chevron, no device-summary
duplication, no content glass), empty quota/Today, no-devices Mac setup without a QR code or raw
URL, cached content with a plain status Label, subscription detail (Account, Plan, Quota, Readings),
Devices content and empty, Usage at 30 Days as one native scrolling List (period control, totals,
Activity heatmap with full month abbreviations, agent sections, no glass cards), Usage empty /
activity loading / activity failed, a single-day sheet (populated, empty, failed) with system
chrome and medium/large detents, the four tabs (tab-bar minimization is a manual gate), Settings
hub (Notifications and Appearance links, Log Out, Delete Account), Settings › Notifications,
Settings › Appearance, Settings › About, and each widget family in placeholder, content, and
no-data states. Check iPhone, light and dark, standard and accessibility text sizes, VoiceOver
labels, Reduce Motion, and Reduce Transparency. Synthetic fixtures may contain display labels
only; they must never contain access tokens, refresh tokens, or production data.

`scripts/ios-ui-screenshots.sh` exports the `connect-signed-out`, `connect-connecting`,
`connect-error`, `connect-expired`, `connect-refresh-failed`, `root-loading`, `confirm-account`,
`overview-content`, `overview-cached-error`, `overview-empty`, `overview-no-devices`,
`overview-scrolled`, `subscription-detail`, `devices-content`, `devices-empty`,
`usage-content`, `usage-activity`, `usage-activity-loading`, `usage-activity-failed`,
`usage-empty`, `usage-day`, `usage-day-empty`, `usage-day-failed`, `overview-sync-off`,
`settings-sync-active`, `paywall`, `paywall-unavailable`, `settings-main`,
`settings-notifications`, `settings-appearance`, `settings-about`, and `settings-providers`
fixture screenshots to
`dist/ios-ui-screenshots/`. `QUOTA_IOS_TEXT_SIZE` (for example `accessibilityExtraLarge`) and
`QUOTA_IOS_APPEARANCE` (`light` or `dark`) select Dynamic Type and appearance for that run; variant
PNGs land in a subdirectory. Re-run Connect, Confirm, Overview, Usage, Devices, subscription
detail, and each Settings destination at one accessibility text size.

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
--visual-fixture local-only
--visual-fixture merged
--visual-fixture providers
--visual-fixture activity-loading
--visual-fixture activity-failed
--visual-fixture activity-day-empty
--visual-fixture activity-day-failed
--visual-fixture sync-off
--visual-fixture sync-active
--visual-fixture paywall
--visual-fixture paywall-unavailable
--visual-fixture sign-in
--visual-fixture sign-in-methods
```

| Fixture | UI state |
| --- | --- |
| `signed-out` | Signed-in tabs with nothing read: **No quota yet** and both invitations. No session restore |
| `sign-in` | The sign-in sheet over a phone that read its own providers: **Continue with Apple**, **Continue with GitHub**, **Continue with Email** |
| `connecting` | Disabled **Connecting…** button with visible progress on neutral glass |
| `connect-error` | Empty Overview plus the **Couldn't connect. Try again.** status |
| `expired` | Empty Overview plus the **Session expired. Connect again.** status |
| `connect-refresh-failed` | Pending session after a failed first refresh: **Retry**, **Use a different account**, **Couldn't reach quota.gotry.io.** No Continue |
| `confirm-account` | Inline signed-out confirmation for **octocat**: mark, **Use this GitHub account?**, **Continue**, **Use a different account** |
| `loading` | Centered **Loading account…** |
| `content` | Signed-in Overview with synthetic Codex / Claude / Grok windows and Today values. Claude has a last-good `minor` status-page reading (**Partial System Outage**), so the row shows the 8pt incident dot. Codex reports from two devices so subscription detail can show per-device readings; Usage has four periods with increasing totals, one provider group of more than five models, and an in-memory Activity heatmap of the last 365 UTC days |
| `cached-error` | Same content plus **Showing saved data. Couldn't refresh.** |
| `empty` | Signed-in Overview with empty quota and **No usage today.** Devices remain so Mac setup does not occupy this screen. Usage of every period is **No usage** / **No usage was reported for this period.** Activity is **No activity in the last year.** |
| `no-devices` | Signed-in Overview with no devices and no subscriptions (compact Mac setup Section) |
| `local-only` | No account, two subscriptions this phone read for itself: Overview titled **Quota**, no Today Usage section, and **This iPhone** as the only reading on subscription detail. Its sample journal is filled in, so each window draws a pace line and the detail page carries the **Today** windows section |
| `merged` | The `content` account plus a newer local reading of the same Codex subscription: one row, three sources, **This iPhone** reporting |
| `providers` | Signed-in Settings with the Providers group in its three states: Codex with two connected accounts, Claude Code with one, and Grok with none. The second Codex account was refused on the last collection, so it shows **Sign in again**. The stored fixture cookie is not a session and reaches no provider |
| `activity-loading` | Signed-in Usage with populated period totals and the Activity skeleton |
| `activity-failed` | Signed-in Usage with populated period totals, **Couldn't load activity.**, and **Retry** |
| `activity-day-empty` | Signed-in Usage presenting a day sheet with **No usage on this day.** |
| `activity-day-failed` | Signed-in Usage presenting a day sheet with **Couldn't load this day's usage.** and **Retry** |
| `sync-off` | Signed-in Overview whose entitlement is `none`: the sync-off row above Quota |
| `sync-active` | Settings with the Sync group showing **Active · renews `<date>`** and **Manage** |
| `paywall` | Settings with the paywall's two plans priced from a fixture store, no network |
| `paywall-unavailable` | The same screen in a build with no RevenueCat key: **Purchases unavailable in this build.** |
| `sign-in-methods` | Signed-in Settings with the Sign-in methods group in every row state: GitHub bound as **octocat**, Apple bound with no label (**Linked**), Email **Not linked** with **Link on Web** |

Fixtures construct `AppModel` UI state in-process, skip Keychain/network restore, and never embed
access tokens, refresh tokens, or production data. Release builds ignore the flag. Launch-time
fixtures anchor synthetic timestamps to the process launch instant so Updated age and reset
instants stay current; unit tests inject `VisualFixture.referenceDate` for determinism.
