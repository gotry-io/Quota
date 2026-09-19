# QuotaBar Design

This file is the canonical visual and interaction specification for native macOS QuotaBar: the
menu-bar panel and one main window. Website marketing UI belongs in `apps/web/DESIGN.md`.

## Product character

QuotaBar should feel like a precise macOS instrument: compact, calm, legible, and immediately useful.
It uses system materials and controls, a restrained accent, and dense information hierarchy. On
macOS 26 the main-window chrome, cards, and floating menus use Liquid Glass; macOS 14 and 15 use
the material fallback. The panel is an app-owned SwiftUI surface, not a website compressed into a
popover. The main window is a titled window; it is not the panel stretched.

Core rules:

1. Remaining quota is the primary value. Usage and account state support it without competing.
2. The panel shares one header, one footer, and one typed navigation stack across Overview and
   provider detail. Quota, Today, Usage, and Settings are pages of the main window, not of that
   stack.
3. Account actions are plain user tasks: continue with GitHub, inspect devices, inspect Usage, log
   out.
4. QuotaBar displays typed local-service results. Provider configuration exposes only intentional
   API-key entry and masked saved state, never stored secrets, opaque account identifiers, or raw
   diagnostics.
5. Every action remains keyboard reachable, VoiceOver labelled, and usable with Reduce Motion and
   large text.

## Shared product vocabulary

These rules apply to every Quota client, not only the menu panel. `apps/web/DESIGN.md` and
`apps/ios/DESIGN.md` cite this section rather than restating it.

- **Freshness is relative age, everywhere.** A current reading reads **Updated 3m ago**. A reading
  that no longer describes current quota names why and when it was last taken:
  **Not current — last reading 2d ago**, or **Sign-in needed**, **Unavailable**, **Unsupported**,
  **Can’t refresh** in place of *Not current* when the source itself reported that. Anything under a
  minute is **just now**, because a number that changes while it is being read is noise. Nothing
  shows a clock time or a calendar date for a past reading, and nothing shows a bare age with no
  words around it.
- The exact phrases and thresholds are `packages/protocol/fixtures/freshness-copy-conformance.json`.
  `packages/apple-shared` (`FreshnessCopy`) and `apps/web/src/lib/format.ts` both answer that file,
  so a phrase one of them changes cannot drift from the other. Change the fixture, not a surface.
- **A future reset is a countdown or a local date, never an age.** All of it is relative to the
  reader’s time zone, and the English is fixed: it does not follow the device locale. Relative
  (the default): under an hour **Resets in 42m** (minutes round up; anything under a minute is
  still **Resets in 1m**); from one hour to a day **Resets in 3h 12m**, or **Resets in 3h** when
  the minutes are zero; from a day to a week **Resets Tue 14:00** (weekday abbreviation and
  24-hour `HH:mm`); a week or more **Resets Sep 12** (month abbreviation and day). Absolute always
  uses that local date, even under a day. A reset that has already passed prints no Resets line;
  the reading is **Not current**, or the status word the source reported.
  `packages/protocol/fixtures/reset-copy-conformance.json` is the shared statement; QuotaBar
  Settings → Menu Bar → **Reset time** switches relative and absolute. iOS and the website stay
  on relative.
- **usd and credits remaining of a cap print `$12.50 of $40.00` (or `80.00 of 100.00 credits`)
  and drop the percent bar**, when remaining/limit describes the same quantity as `used_percent`.
  Included dollars that are a different quantity keep `36.9% · $14.55` and the meter.
  `packages/protocol/fixtures/remaining-copy-conformance.json` is the shared statement.
- **A pace line says whether the current rate lasts to the reset.** One line under the window, in
  two halves: the tempo, then the outcome — **On track · lasts to reset**, **Ahead +42% · runs out
  ~2h before reset**, **Behind −30% · lasts to reset**. *On track* carries no number; *Ahead* and
  *Behind* carry the signed difference from an even burn rate. The duration in *runs out* is the
  shared compact format (`2h`, `27m`, `1d`) and always reads `~`, because it is a projection. A
  window the rule cannot answer for — no cadence, a balance with no limit, or too little of the
  window elapsed or used — shows no line and takes no space. *runs out* is the warning color;
  everything else is secondary text. The rule and these phrases are
  `packages/protocol/fixtures/quota-pace-conformance.json`, answered by `packages/quota-model`,
  `packages/service`, `packages/apple-shared` (`QuotaPace`, `QuotaPaceCopy`), and
  `apps/web/src/lib/format.ts`; see
  [ADR 0035](../../docs/decisions/0035-quota-pace-is-derived-from-the-reading.md).
- **A pace line has a picture: the window's own samples, drawn under its meter.** A 22pt sparkline,
  solid over the readings this Mac took inside the running window, dashed from the last of them to
  where ADR 0035's projection lands at the reset. The vertical axis is the whole window, 0 to 100
  percent used, so two windows of different cadences are read the same way; the horizontal axis is
  the window's start to its reset. It takes the meter's own color. A window with no samples yet —
  a new install, a rebuilt cache, a reading that came from another device — shows no line and takes
  no space.
- **A provider group ends with the day it has had.** One secondary line,
  **Today: 3 windows · 82% / 40% / 12%**, oldest first, that opens into a row per window naming the
  local clock times it ran between and its peak. Singular is **1 window**. The day is the
  primary-cadence window's — the same window Quota iOS names its Today section after, so both
  surfaces answer for one window rather than for whichever happened to have samples. A provider whose day
  holds no window shows nothing. Both the line and the sparkline are turned off together by
  Settings → Menu Bar → **Show pace lines**, on by default. The fold is
  `packages/protocol/fixtures/quota-history-conformance.json`, answered by `packages/service` and
  `packages/apple-shared` (`QuotaHistory`, `QuotaHistoryCopy`); see
  [ADR 0042](../../docs/decisions/0042-quota-history-is-local-samples.md).
- **A window with no reported refill instant reads “No reset time reported.”** One phrase. A percent
  window that is still full omits the line: there is no refill to wait for.
- **Provider names come from the catalog.** `display_name` in `packages/provider/catalog.json` is
  the only place a provider is named for a person. No surface keeps a second table and none derives
  a name from an identifier.
- **Billing agent names come from `BillingAgent.displayName`.** QuotaWire owns that table beside
  `ProviderID.displayName`. No surface keeps a second table.
- **Quota window titles are Title Case.** Cadence names are **5 Hours**, **Weekly**, and
  **Monthly**. Acronyms keep their standard forms: **GPT**, **API**, **OAuth**, **USD**. Extra Codex
  limit names follow that rule (`gpt-reserve` reads **GPT Reserve**). Collectors write these titles;
  surfaces print them as received.
- **A device row states one verdict and the one age it came from**: **Active** under thirty minutes,
  **Idle** up to a day, **Not reporting** beyond that, and `last reading 5m ago` from the instant
  that decided it. Never a list of report, refresh, and sync timestamps.
- **User-facing copy uses product words.** Nothing on screen names coverage, UTC hours, generations,
  revisions, fingerprints, sequences, protocol versions, or the private service's implementation.
  Counting how many readings came from this Mac and how many from the account is implementation
  detail; whether the numbers are still current is not. **This Mac** and **Account** remain valid as
  the two Usage sources a person picks between.
- **Notification copy.** Title is **`<Provider display_name> · <Window title>`**. Body is
  **`12% left · resets in 42m`**, using the shared reset countdown in lowercase; if that countdown
  is nil, the body is only **`12% left`**. A window refill reads **`<Window title> quota reset`**.
  Product copy says Quota reminds when a refresh brings new data; it does not promise real-time.
  When a remaining-quota reading should fire a local threshold or reset notification is
  `packages/protocol/fixtures/alert-transition-conformance.json`; QuotaBar and Quota iOS both
  answer that file through `QuotaAlerts`. A pace warning reuses the pace line as its body, and fires
  at most once per window per reset cycle.
- **A Usage page shows one period, and there are seven of them.** Three are anchored to the
  reader's own calendar and step a unit at a time — **Today**, **This week**, **This month** — and
  three are fixed windows — **Last 7 days**, **Last 30 days**, **All**. The seventh is **Custom
  range**, two inclusive dates someone picked. Relay's `all` is the last 730 UTC days, not every
  day ever stored. A control too narrow for the full name abbreviates it **Day**, **Week**,
  **Month**, **7D**, **30D**, **All**, **Custom**; the accessibility name is always the full one.
  `UsagePeriodSegment` in `packages/apple-shared` and `USAGE_PERIOD_SEGMENTS` in
  `apps/web/src/lib/usage-period.ts` are where those pairs are written.
- **A period says the range it covers, not the name of its button.** One day is that date
  (**Sep 6, 2026**); a range inside one year drops the repeated year from its first half
  (**Aug 31 – Sep 6, 2026**); `all` has no first day, so it reads **Everything kept**. The
  step controls are **Previous period** and **Next period**, and there is nothing ahead of the
  current day, week, or month, so **Next period** is disabled there.
- **Four periods are folded for the reader, and the rest are folded by the client.** Today, Last 7
  days, Last 30 days, and All arrive folded — from the service on This Mac, from the Account read
  on Account. Every other period is added up by the client from days it already holds, and days
  carry no agent tree, so a folded period shows totals and cost with no model breakdown and says
  so in one line rather than looking empty. On Account, a period the summary does not carry is
  answered on This Mac only.
- **The monthly budget is a device preference and never leaves the device.** It is one amount in
  whole US dollars plus whether it may notify, kept in `UserDefaults` on Apple and `localStorage`
  on the website — never in the Account, because a budget says what someone wants to be warned
  about, which is not a fact about their usage. The Usage page shows it as a progress bar above
  the totals, reading **`$5.39 / $50.00 · 11%`**, with **`≥ `** in front of a spend only partly
  priced. Crossing 80% and then 100% of the amount notifies once each per calendar month: the
  title is **`Monthly budget`** and the body is **`80% of $50.00 spent`**, or **`$50.00 budget
  spent`** once the whole amount is gone. A new month starts a new cycle. When those
  crossings fire is `packages/protocol/fixtures/alert-transition-conformance.json`
  (`budget_cases`), which both Apple apps answer through `QuotaAlerts`.
- **An empty day is a tick, not a bar.** A day the period covers that reported no usage is drawn
  as a 2-point baseline tick in the tertiary fill, so the day is present and has no height. It is
  never a short bar of usage. In Cost mode, a day the catalog could not price is a distinct
  **unpriced** mark at that same tick height — hatched or outlined — and is named unpriced, never
  **$0**. Spoken chart summaries follow the Tokens / Cost mode the bars are measuring.

## Window and layout tokens

| Token | Value | Purpose |
| --- | ---: | --- |
| `panelWidth` | 320pt | Fixed menu-panel width |
| `panelMaxHeight` | 480pt | Shared fixed panel height |
| `panelHorizontalPadding` | 16pt | Header, content, and footer gutter |
| `pageVerticalPadding` | 16pt | Page content inset |
| `headerHeight` | 44pt | Navigation and title chrome |
| `footerHeight` | 36pt | Today's spend and the refresh action |
| `minimumInteractiveDimension` | 28pt | Minimum pointer target |
| `settingsRowHeight` | 38pt | Single-line settings row |
| `settingsListRowHeight` | 46pt | Title/subtitle list row |
| `fieldMinHeight` | 32pt | Compact controls and command surfaces |
| `controlMinHeight` | 36pt | Primary capsule button |
| `groupCornerRadius` | 10pt | Persistent settings group |
| `rowCornerRadius` | 6pt | Nested hover/press surface |
| `fieldCornerRadius` | 7pt | Editable/control surface |
| `groupContentInset` | 8pt | Content inside a group |
| `groupSurfaceInset` | 4pt | Hover surface inset |
| `windowSidebarWidth` | 220pt | Main window sidebar min/ideal |
| `windowSidebarMaxWidth` | 280pt | Main window sidebar maximum |
| `agentsListWidth` | 220pt | Provider list inside the Agents page |
| `mainWindowMinSize` | 960×640 | Main window minimum content size |
| `cardCornerRadius` | 20pt | Quota / Today / Usage cards |
| `cardPadding` | 16pt | Inner padding of those cards |
| `contentMaxWidth` | 1040pt | Main-window reading column |
| `contentGutter` | 24pt | Horizontal gutter around that column |
| `settingsContentMaxWidth` | 720pt | Settings Form pages, centred in the detail column |
| `floatingSurfaceCornerRadius` | 14pt | Transient menus (`quotaFloatingSurface`) |
| `menuBarStripHeight` | 24pt | Simulated menu-bar strip on Settings → Menu Bar |
| `columnHairlineWidth` | 1pt | Agents page column divider |

Spacing uses 4, 6, 8, 12, and 16pt semantic steps. Avoid page-specific magic numbers. Scroll only the
page body; header and footer remain fixed. Content aligns to the same 16pt guide at every depth.

## Windows

The main window is a standard titled `NSWindow`, not the panel. It uses `windowBackgroundColor`
rather than the panel material, a user-resizable sidebar (220–280pt), a 960×640 minimum content
size, frame autosave name `QuotaBarMainWindow`, level `.normal`, and `collectionBehavior` including
`.fullScreenPrimary`. It is resizable and miniaturizable and may go full screen. Esc and ⌘W close
it. The title is **QuotaBar**.

QuotaBar lives in the menu bar. **Show in Dock** (General, default off) on keeps the process
`.regular` even when the window is closed. Off (the default) makes QuotaBar menu-bar-only: the
main window registers with `WindowActivation`, which switches the process to `.regular` so a
Dock icon and ⌘Tab entry exist while that window is open, and closing it returns to `.accessory`
without activating. Toggling the switch while the main window is open does not close it or move
focus. A launch as a Login Item does not show the main window. A manual launch (Finder,
Spotlight, `open -a`) shows the main window until this Mac has shown quota, then opens the
menu-bar panel after the status items exist; **Open window at launch** (General, default off)
always shows the window on a manual launch. Closing the main window never quits; a Dock click
reopens it. A plain Quit (⌘Q) while the main window is open closes that window and keeps the
menu bar; **Quit QuotaBar Completely** ⌥⌘Q, the panel overflow **Quit QuotaBar**, a system log
out, and an update relaunch terminate. Browser Access and Sparkle windows are not registered.

The process has a regular-app menu bar:

- **QuotaBar:** About QuotaBar, Check for Updates…, Settings… ⌘,, Services, Hide QuotaBar ⌘H,
  Hide Others ⌥⌘H, Show All, Quit QuotaBar ⌘Q, Quit QuotaBar Completely ⌥⌘Q.
- **File:** Close ⌘W.
- **Edit:** Undo, Redo, Cut, Copy, Paste, Select All.
- **View:** Quota ⌘1, Today ⌘2, Usage ⌘3, Refresh ⌘R, Enter Full Screen (⌃⌘F).
- **Window:** Minimize ⌘M, Zoom, QuotaBar (brings the main window front), Bring All to Front.
- **Help:** QuotaBar Help (opens the website), Feedback.

The sidebar is a `List` with `.listStyle(.sidebar)` and two `Section`s: **Quota**
(**Quota**, **Today**, **Usage**) and
**Settings** (**Account**, **Agents**, **Notifications**, **Menu Bar**, **General**, **Support**).
Rows are `Label`s. On macOS 26 the system draws the floating glass sidebar; on 14/15 it is the
standard sidebar. The selected page persists in `main.page`; the first open lands on Quota. Provider
selection for Quota is a toolbar menu (**All providers** and each shown provider with its brand
icon), not sidebar rows. The closed menu shows the selected provider's brand icon, or Quota's mark
when **All providers** is selected. The selection is not persisted. Account, Notifications,
General, Support, and **Menu Bar** are grouped Forms in the detail column, content at most 720pt
and centred. **Menu Bar** is one form (preview strip, Style, Provider, Reset time, Show pace
lines). The **Agents** row keeps a `.badge` of
**3 shown** and, when any shown agent has no working credential and no device reporting it,
**· 1 needs sign-in**; the Agents page is a two-column list and provider detail.

The Quota-group toolbar groups **Provider**, **Range**, and **Usage source**, then a flexible
spacer, then **Refresh**. On macOS 26 `ToolbarSpacer` separates those groups into glass capsules;
on 14/15 the same items appear without spacers. Refresh is on every page.

Quota, Today, and Usage scroll under the toolbar and sidebar (`quotaScrollEdge()`, a soft
scroll-edge effect on macOS 26). Their content is one column, max width 1040pt, centred, with 24pt
gutters and 16pt between cards.

## Main window

The main window is where this Mac's quota history is read at width, and where every preference
lives. It does not collect, and every number the Quota, Today, and Usage pages show is already on
this Mac: local samples through `quota_history`, and the current reading Overview already has.

The Quota-group toolbar holds a provider menu — **All providers**, then each provider shown in
Overview, in Overview order, each with its catalog brand mark; the closed control is that
provider's brand icon — the history range — **Today**,
**7D**, **30D**, persisted as `dashboard.range`, default 7D — a Usage source picker (**Account** /
**This Mac**) that the Usage page honors, and a refresh action that uses the same tooltip as the
panel footer: **Refresh all quota. Updated 3m ago**, or **Not checked** before any sync. The Usage
source picker is hidden when Account data is unavailable or Usage sync is disabled; in those states
Usage is unambiguously This Mac. Changing source preserves the selected period. Refresh is on
every page. **All providers** shows every shown provider's card; selecting a provider shows that
provider only.

### Quota

One card per subscription in the detail column. Several accounts of one provider each have their
own card; the provider filter still narrows to that provider. Each card uses `quotaCardSurface()` (glass on macOS 26,
`settingsGroupFill` otherwise), 20pt continuous corners, and 16pt inner padding. The header is two lines:
the catalog brand icon and provider name as the title, with the remaining percent of the primary
window trailing as a 28pt semibold rounded numeral and a small **remaining** caption; then the
pace phrase ADR 0035 already prints for the current reading, the reset copy for that reading under
the Menu Bar **Reset time** preference, and `QuotaHistoryCopy.peak` of the current window, in
secondary style, joined by ` · `. Parts the reading does not have are omitted.

Each card draws one Swift Charts `LineMark` per window of used percent over time, from this Mac's
samples in the selected range, 180pt tall, with tertiary axis labels. The running window continues
to its reset as a dashed `LineMark` at ADR 0035's projection, and a `RuleMark` marks the reset.
Line colour is the remaining-quota tone (healthy / warning / critical) of that window; windows of
the same provider are told apart by opacity in rank order, the first cadence window at full
strength. No second palette.

Every chart has an `accessibilityChartDescriptor` that names each window, its start, now, and the
projected end.

Empty states: while the cache is rebuilding and this Mac has no samples yet, the card reuses
**Usage history is catching up** / **Quota and Account stay available.** A provider that is not
signed in reuses `SignInRungPresentation.statusLine`. A signed-in provider with no samples yet
reads **No history yet**.

### Today

A table on the Today page, inside one `quotaCardSurface()` card. One row per provider × window that had samples
today, 36pt tall. The header row is tertiary caps. Columns: window (catalog provider name · window
title), used percent at the start of the local day → now (`12% → 47%`, the same whole percents
`QuotaHistoryCopy.peak` prints, with the arrow in tertiary), cost today when today's Usage can
attribute it to that provider, and the reset time — the same reset copy the Quota header uses, or
the local clock time when that reset has already passed. The panel's
`Today: 3 windows · 82% / 40% / 12%` sentence stays on Overview; the main window lays those facts in
columns. A provider or window with no sample today is omitted. Toolbar provider selection narrows
the rows the same way it narrows Quota cards.

### Usage

Usage defaults to Account when an account summary is available and Usage sync is enabled; otherwise
it uses This Mac. The source menu is the main-window toolbar on Quota, Today, and Usage; omit it
when Account data is unavailable or Usage sync is disabled. Changing source preserves the selected
period.

A six-item 28pt tab control selects Day, Week, Month, 7D, 30D, or All; Today is the default. Its
labels use the regular 10.5pt list-secondary type size. The control owns one overall neutral
background, with the selected item highlighted inside it; do not wrap it in a card.
A custom range selects none of the six, so the tab control shows nothing selected and the row
beneath it says what the period covers. At main-window width the control is leading-aligned and no
wider than 480pt.

Under the tabs is one 28pt row: **Previous period**, the range title, **Next period**, and a
calendar button that opens two inline date fields and an **Apply**. Stepping applies only to Day,
Week, and Month, and the current one is the last, so both arrows are disabled on a fixed window
and **Next period** is disabled on the current unit. The period names, the range title, and the
budget copy are in Shared product vocabulary.

Today, 7D, 30D, and All come out of the service's precomputed snapshot, so opening Usage and
changing either selector starts no collection or network work and shows no loading state when a
snapshot already exists. Every other period is one `usage_period` request, which folds the hours
this Mac already stored rather than collecting again; while it is in flight the page says
**Preparing Usage…**, and a state change discards those folds and asks again because the hours
behind them moved. The Account read hands this device four folds, not the days behind them, so on
Account a period outside those four says **This period is folded from this Mac's own hours. Switch
the source to this Mac to see it.** If the selected source has no snapshot yet and that
component is still refreshing, the page says **Preparing Usage…** instead of implying Usage is
absent. After refresh finishes with no snapshot, it says **No Usage is available for this period.**
Preparing and empty Usage remain section states below the period tabs because those controls are
still useful. Cached account refresh failures and partial Usage warnings are inline notices and do
not replace available content.

When this Mac has a monthly budget, a **Monthly budget** card sits above the summary with a
progress bar and one line of `spent / budget · percent`. The bar measures this month's local spend,
folded the same way any other custom period is, and it is shown whatever period the page is
otherwise on. The budget is set in Notifications settings; it never leaves this Mac.

The default page contains:

- Summary: three stat tiles in a row — Tokens, Cost, and Cache hit — each a card with a 28pt
  semibold rounded numeral, a small label, and `saved $X.XX` as the Cache hit caption when the
  period's cache reads could be priced (nothing under it when they could not)
  ([ADR 0036](../../docs/decisions/0036-usage-derived-metrics.md)). The six token and message
  metrics follow in their own Summary card as a three-column grid. Headline values use the
  primary text tone; grid labels stay muted while their values use the secondary tone. Values use
  `UsageValueFormatter`.
- Daily, for This Mac and for any period but All, in its own card: one Swift Charts `BarMark` per
  local day of cost, using the ADR 0036 `days[]` fold as received — the view does not fold again.
  Empty and unpriced days follow **An empty day is a tick, not a bar** in Shared product vocabulary.
  The last seven of those days follow as `date` / `tokens · cost` rows. Omit the section when the
  period reported nothing. All has no Daily section: its per-day shape is the Account's activity
  chart.
- Models, in its own card: grouped by the vendor whose model it is — the service resolves that from
  the model's name — independent of the collecting client and of who billed the request. A **Top
  models** list of the three largest leads the section when there is more than one, each as
  `share · tokens`. Each provider heading is followed by a 4pt share bar and its whole-percent
  share of the period. Every model remains a static single row ending in `tokens · cost · share`
  when priced, or `tokens · share` when unpriced.
- Rhythm, for This Mac and for Account, and for any period but All, in its own card: 24 bars at
  36pt, one per hour of the local clock, then Morning / Afternoon / Evening / Night, each as a
  whole-percent share. Omit the section when every hour is empty. Account hours come from
  `GET /api/v6/account/usage/activity?from&to&detail=hours&tz=` in this Mac's zone
  ([ADR 0036](../../docs/decisions/0036-usage-derived-metrics.md)).
- Projects, in its own card: This Mac only, and only while **Group Usage by project** is on (an
  Account period carries no `projects` key at all — attribution never leaves the Mac that made it).
  A table of at most 50 repository basenames for the selected period, columns Project / Tokens /
  Cost, with the top model as a meta line under the name. Unattributed work and the overflow past
  50 share the row **Other**. Account Usage has no such section.
- Sessions, in its own card: This Mac's session files, independent of the Account / This Mac
  summary source. The section header trails `2 active · 14 today`. Each row is the agent mark, a
  basename project label, a relative age (`just now`, `3m ago`), and `tokens · cost` using the same
  compact cost copy as Models. A session written in the last five minutes wears a 6pt accent dot on
  the mark. At most 20 rows, newest write first. An empty list says **No sessions in the last 90
  days.**

Provider headings use the brand mark of the structured provider the service sent; the client never
reads model text to pick one. Model rows have no repeated icon and align under the provider label. When no owned brand asset
exists, use an honest semantic system symbol rather than another provider's logo. Approved
monochrome brand assets come from the Lobe Icons source recorded in the bundled third-party notice.
Every provider, regardless of model count, uses the same separate noninteractive heading with a 14pt
provider icon. The Models surface has 8pt vertical insets, provider groups have 8pt between them, and
each heading has 4pt before its compact static model rows; model rows also have 4pt between them.
Model rows have no icons or disclosure controls and use regular secondary text. Each provider shows
at most the first five models in the existing cost/tokens order. If the same provider/model pair
appears through more than one client, append the client name only to disambiguate those rows.

Dates, cost metadata, and how the prices were sourced are not separate default sections. Complete
data shows no diagnostic copy. Partial collection produces one compact warning. An unavailable
summary cost uses `— unpriced`, while model rows omit unavailable cost entirely; neither state adds
another alert. Technical detail remains available through Support.

Usage counts use locale-aware decimal formatting below 1,000 and compact SI-style `k`, `M`, and `B`
suffixes for larger values. Usage groups use priced-cost-first ordering, then fall back to tokens and
name for stability.

Compact cost copy is exact:

- complete: `$X`;
- partial: `≥ $X`;
- unavailable: `— unpriced`.

Do not infer missing prices, silently treat partial cost as total cost, or recompute typed output.
Summary and model values use two fractional digits to preserve the single-line layout.

## Material and color

The panel inherits the menu extra's system material. The main window uses
`windowBackgroundColor`, not that material. Add only adaptive semantic layers:

- Panel: transparent material plus `panelWash`.
- Group: `settingsGroupFill` with a continuous 10pt silhouette.
- Card: `quotaCardSurface()` — glass on macOS 26, `settingsGroupFill` at 20pt continuous otherwise.
- Control: `fieldFill` plus the accent focus ring.
- Transient: `quotaFloatingSurface()` — glass on macOS 26; on 14/15 regular material plus
  `floatingMenuFill`, a 0.5pt adaptive edge, and restrained shadow.
- Hover/press: `rowHoverFill` and `rowPressedFill` nested inside the group or card.

Use `QuotaPalette` roles instead of fixed RGB values. `ink` is for primary text and marks, `body` for
supporting copy, `mute` for tertiary metadata, `accent` for primary action/focus/progress, and
`critical` only for failure or destructive meaning. Native system red remains the destructive color.
Remaining-quota meters use the shared healthy/warning/critical bands ≥40 / ≥15 (`QuotaTone`);
`critical` on text stays failure-only.

Do not add decorative gradients, a second card language, colored page backgrounds, or custom window
chrome. Main-window Quota / Today / Usage cards are the 20pt `quotaCardSurface()`.

## Liquid Glass (macOS 26)

QuotaBar uses Apple's native Liquid Glass on macOS 26. Views never branch on availability.
Tahoe-only modifiers live in `QuotaSurfaces` (`quotaCardSurface()`, `quotaFloatingSurface()`,
`quotaScrollEdge()`): they apply `.glassEffect` / `.scrollEdgeEffectStyle` on 26 and the existing
group-fill / material fallbacks below it. `QuotaPalette` stays the one palette.

| Surface | macOS 26 | 14/15 fallback |
| --- | --- | --- |
| Main-window sidebar | System floating glass (`List` `.sidebar`) | Standard sidebar |
| Toolbar groups | Glass capsules (`ToolbarSpacer`) | Same items, no spacers |
| Quota / Today / Usage cards, Usage stat tiles, Agents list groups | `quotaCardSurface()` glass, 20pt continuous | `settingsGroupFill`, same 20pt |
| Transient menus (Overview overflow, `QuotaChoiceMenu`, `QuotaSelectionPopup`, `QuotaConfirmationPopup`) | `quotaFloatingSurface()` glass, 14pt continuous | `quotaFloatingMenuSurface()` |
| Panel background | Menu extra's system material | Same |
| Settings Form pages | Grouped Form; no opaque page wash | Same |
| Main-window background | `windowBackgroundColor` | Same |

The panel background stays the extra's material on every release. Sidebar, toolbar, cards, and
floating menus are the glass surfaces.

Concentric radii on a card: 20pt outer → 12pt inner → 7pt control (`fieldCornerRadius`). Nested
rounded rects share a centre of curvature. Settings groups stay 10pt / 6pt (`groupCornerRadius` /
`rowCornerRadius`) with the 4pt nested inset.

State colours — remaining-quota healthy / warning / critical, `accent`, `warning`, `critical` —
keep at least 4.5:1 on both appearances against the card and floating surfaces. If a tone fails,
darken or lighten that tone. Do not add a second palette.

Quota, Today, and Usage are one column, max width 1040pt, centred, with 24pt gutters and 16pt
between cards. Usage totals are three stat tiles (Tokens, Cost, Cache hit): a 28pt semibold
rounded numeral and a small label. Dense tables stay dense and sit inside the card.

## Typography

Use semantic roles from `QuotaDesign.Typography`:

| Role | Size/weight | Use |
| --- | --- | --- |
| `overviewProviderTitle` | 15pt semibold | Overview provider heading |
| `panelTitle` | 13pt semibold | Header title |
| `emptyTitle` | 13pt medium rounded | Empty-state title |
| `rowTitle` | 13pt medium | Provider/account title and primary buttons |
| `settingsLabel` | 12pt medium | Settings labels |
| `sectionHeader` | 11pt semibold | Quiet section titles |
| `listSecondary` | 10.5pt regular | One-line row support |
| `secondary` | 11pt regular | Body support and recovery copy |
| `meta` | 10pt regular | Age, state, and tertiary metadata |
| `mono` / `monoMeta` | 11pt / 10pt | Commands and technical values |
| `remainingValue` | 12pt medium | Remaining quota |
| `statValue` | 28pt semibold rounded | Remaining % and Usage stat numerals on main-window cards |

Dynamic Type scales semantic text roles. Utility symbols keep their optical sizes, while their hit
targets stay at least 28pt. Technical strings and chevrons never receive primary-text emphasis.

## Menu bar item

The item is the product's first sentence: remaining quota is legible without opening anything.
Each status item is a template mark plus the remaining percent of one current subscription — or,
when **Combined**, up to three such readings packed into **one** template image. By default the
bar shows **Automatic**: the most constrained current subscription — the smallest remaining
percent across every window of every Overview reading that still describes live quota. A lone item
that answers for one subscription then shows that subscription's **primary cadence pair** when it
has one: two remaining percents stacked in the same 18pt image, short cadence above long, the way
a network extra stacks up and down. The wire names the headline meter for each cadence
(`five_hour`, `weekly`, `monthly`), so the item does not parse titles to decide the pair. Compact
tags are one letter — **H**, **W**, **M** — because a tag is read against the tag beside it, and
an item pays for every point of width it takes. Model-scoped, top-up, and feature-scoped windows
carry no cadence and never occupy a stacked line. A subscription that names no cadence but
carries two plan meters — Cursor Models beside Other Models — still stacks: the first two percent
meters in wire order are its headline pair, because collectors emit headline meters before
extras, and the rows wear no tags, told apart by position and their spoken titles rather than by
a letter nobody assigned. **Every arrangement stacks**, Combined included: three pairs cost about
27pt more than three lone percents, which is not a reason to show a person half of what the
reading says. A subscription with only one headline meter stays a single remaining percent — one
number has no neighbour to be told apart from, so it wears no tag — and it keeps the menu bar's
own size beside a pair, because only a pair has two rows to fit. A reading the source reported as
failed, or one the shared freshness rule has aged out, answers for nothing. Balance-only windows
have no budget to be a percent of and never claim the Automatic slot, but a named cell whose
subscription is only a wallet shows its whole-dollar balance — **$99** — because a named cell
owes the person its number; the panel keeps the cents. Ageing out is a fact about the clock rather than about
anything the service says, so each item re-asks the question once a minute — the freshness rule's
smallest unit — and a Mac that stopped collecting loses its number without waiting for an event
that is never coming. An item is only rebuilt when that answer changed.

The mark and the number are composed into **one template image per status item**, which is what
the menu bar is given. A status item is one image to AppKit, and AppKit places it exactly as it
places every other one; a stack of views asks two layout systems to agree about where a baseline
is, and they do not. QuotaBar owns the items through `NSStatusItem` so several can share one
panel. An item is a slot: its autosave name is a slot index rather than a reading, so macOS keeps
a `⌘`-dragged position; when the set of readings changes, an existing slot is re-bound to the new
reading rather than destroyed, so the icon does not flash or move and an open panel stays open
under the same item. Only a change in the *number* of readings adds or removes an item. The panel
is aligned to its item's trailing edge, which the bar keeps fixed: a new image resizes the item's
window in place first and the bar moves it into its slot a moment later, so the panel follows the
item's moves and never its resizes.

The image is the standard status-item height — the bar's own thickness less the padding every item
leaves, which is 18pt in the 22pt bar macOS ships — drawn at 2× and marked template. The mark is the
brand of the provider the number belongs to, fitted **by its ink** into a 14.5pt square: catalog
assets fill their own viewBox by wildly different amounts, and matching the box instead of the ink
would make one provider's logo tower over another's, and all of them over the SF Symbol glyphs
beside them. Quota's own mark appears in exactly two places: the Icon style, which says nothing about
a provider, and a lone item with no current number to attribute. A Combined cell whose provider has
no current reading keeps that provider's mark so the strip does not jump, and never borrows another
provider's number.

A single remaining percent follows 4pt after the mark, set in the **menu-bar font** with
monospaced digits so the item does not twitch as it moves, and its baseline is placed so the
digits' cap-height middle is the image's middle. A line box would center the room it reserves for
descenders no digit uses, which is how a number ends up riding high next to a mark. A stacked pair
uses the same family at 9pt medium — at that size regular strokes thin out against the bar, and
bold clots on a retina screen. Two cap-heights and a 2pt gap have to fit the 18pt item, which
puts the ceiling at 11pt; 9pt is a choice inside that, not the limit. Percents share a right-aligned column as wide as the wider
number and no wider, so the % signs share an edge, and the cadence tag follows 3pt after as the
reading's unit, the way a speed carries `KB/s`; each tag centers in the column the widest tag
sets, because letters are proportional where digits are not. A shorter number's slack falls
before it as leading air — ragged left beside the mark — never as a hole inside the reading.
Every text origin snaps to the pixel grid of the raster being drawn — whole points at 1x, half
points at 2x — because a fractional origin lands glyphs between pixels and smears stems into
something both thin and misaligned. The row step rounds up on that grid, so quantization may
widen the air between the rows but never eats it, and a tag's odd slack pixel trails, keeping
the tag against the number it belongs to. A cell drawn as one row has no
second row to line up with, so it pays for its own ink and reserves neither column nor gap. Packed cells sit 8pt apart. The status bar renders a
template image, so remaining quota is not said in color; the image carries a raster for each
display scale, so a 1x screen shows glyphs drawn at 1x rather than a downsampled retina bitmap. `MenuBarLabelLayoutTests` renders the
image and measures the drawn pixels: the mark's ink and the digits' ink share a center within a
quarter point, every mark lands at the same size, and a stacked pair stays the standard item
height.

Settings → Menu Bar → **Style** chooses **Icon**, **Percent**, **Icon and percent** (the default),
**Icon and today cost**, or **Icon and today tokens**.
→ **Provider** chooses **Automatic** — the tightest current subscription — or any set of providers
Overview is showing. Two or three named providers can be **Combined** into one item or **Separate**
as one item each; Combined is the default arrangement for that size, and a fourth named provider
makes the bar Separate. More than one named provider cannot be Icon-only or Percent-only and still
say whose number it is, so those two fall back to Icon and percent; Icon and today cost/tokens
keep their style because each cell still wears a mark. The stored Style is left alone and
applies again when the bar is back to one reading. Both the named set and the arrangement persist
in UserDefaults. A chosen provider with no current reading shows the mark alone and never borrows
another provider's number, and **Percent**, **Icon and today cost**, and **Icon and today tokens**
likewise fall back to the mark alone when there is no number to show, because an item with no
content cannot be clicked.

**Icon and today cost** and **Icon and today tokens** use the same 14.5pt mark, 4pt gap, and
menu-bar font with monospaced digits as a single remaining percent. They are one line, never a
stack: cost is the compact Usage format (`$1.49`, or `≥ $1.49` when the day is partial), tokens
are the compact count (`1.23M`). Automatic answers with Quota's own mark and the same today total
the footer would show; a named cell answers with that provider's mark and that agent's today.
Packed cells sit 8pt apart, the same as percents. VoiceOver announces **QuotaBar, today $1.49**
or **QuotaBar, Claude Code today 1,234,567 tokens**.

VoiceOver for remaining-percent styles announces **QuotaBar**, the provider each number belongs
to, and the remaining percent — or, for a stacked pair, the full window titles: **QuotaBar, Claude
Code, 5 Hours 68% remaining, Weekly 27% remaining**. Clicking a Separate item opens the shared
panel on that provider; Combined and Automatic open the same panel without changing page.

## Shell

The header shows:

- Overview: Quota mark, **QuotaBar**, and an overflow menu containing **Open QuotaBar**,
  **Settings…** ⌘,, **Check for Updates…**, and **Quit QuotaBar** ⌘Q. Opening the menu focuses
  Quit. VoiceOver names the trigger **Settings menu**. **Open QuotaBar** opens the main window
  on the last page (Quota the first time) and does not show a shortcut; View › **Quota** is ⌘1.
  **Settings…** opens the main window on Account or the last Settings page; there is no gear.
  **Quit QuotaBar** quits the process, not only the window.
- Child page: Back and page title. Provider detail has no trailing action.

Transient menus — the Overview overflow, `QuotaChoiceMenu`, `QuotaSelectionPopup`, and
`QuotaConfirmationPopup` — use `quotaFloatingSurface()`: glass in a 14pt continuous rounded rect
on macOS 26, and `quotaFloatingMenuSurface()` (regular material, same 14pt radius) on 14/15. Views
do not branch on availability. Header and footer heights stay 44pt and 36pt. The panel keeps the
menu extra's material.

The bottom bar is fixed at `footerHeight` on every page and carries two things: today's spend on
the left, and one icon-only refresh action on the right. The left reads `Today · $12.34 · 1.2M
tokens` from the Usage source the main window would show and is a button that opens the main
window on Usage (VoiceOver **Open Usage**); cost drops out when the day is unpriced, and the whole line is
absent when there are no tokens. Today's number belongs beside quota everywhere, so it lives in
the bar every page already has rather than in an Overview line of its own.

When the last sync finished is a fact about the refresh action, not a number worth a permanent
line: `arrow.clockwise` carries **Refresh all quota. Updated 3m ago** — or **Not checked** before
any sync — as both its tooltip and its VoiceOver label. It is the age of the last sync, not of
every provider observation. Selecting it runs one sync; while a sync is active the glyph becomes a
small spinner and clicks are ignored.

Navigation transitions move horizontally by direction and combine with opacity. Reduce Motion uses
opacity only. A page change clears transient focus/menu state. Escape dismisses a transient menu;
Back returns one level.

## Information architecture

```text
Panel
Overview
└── Provider (read-only quota)

Main window
├── Quota
│   ├── Quota      (30-day window curves, pace phrase, reset, peak)
│   ├── Today      (per-window used % today, cost when attributable, reset)
│   └── Usage      (Account / This Mac; Day · Week · Month · 7D · 30D · All; Projects)
└── Settings
    ├── Account (Devices on the same page)
    ├── Agents
    │   ├── Shown in Overview / Hidden from Overview (list)
    │   └── Provider (inline: Overview, Accounts, Source, Sign-in, API Key)
    ├── Notifications
    ├── Menu Bar (one form)
    ├── General
    └── Support (Diagnostics disclosure)
```

### Overview

Render the service-provided Overview in saved catalog order. Each provider row may contain multiple
account observations; Rust has already merged global identities and selected one freshest valid
observation. Swift never repeats that policy. Never add or average percentages across devices.

Overview is quota and nothing else. Provider groups carry quota only: models, messages, and period
totals stay on main-window Usage and never create or extend an Overview provider
group. What today cost is the shell's bottom bar, not an Overview row. The provider heading is
the only Overview destination, into a read-only quota page for that provider. Agent settings
live in the main window (**Agents**). Provider groups sit 12pt apart. The heading is 15pt
semibold (`overviewProviderTitle`) and a destination at
`minimumInteractiveDimension` (28pt), not a Settings list row. Window rows are unchanged. Brand,
name, status, and chevron stay on the 16pt content guide with the quota windows. Hover/press
extends 8pt into that gutter on each side, so the bar is wider than the numbers and still
has margin from the panel edge. Overview is not a Settings group and does not use the group's
4pt nested inset. Quota windows, account labels, and status detail under it are static
reading content and do not take that surface. The heading remains keyboard and VoiceOver
reachable. Back follows the stack. A widget deep link `quotabar:/subscriptions/<selection_id>`
lands on that read-only provider page.

Each quota observation shows:

- provider brand and name, with a 6pt incident dot after the name when the official status page
  reports `minor` or worse; the tooltip is the status-page `description`. `none` shows no mark.
  The menu-bar extra never overlays this mark;
- optional masked account label and normalized plan badge;
- remaining value as the strongest number, with no "left" or "remaining" suffix;
- usd/credits windows whose remaining and limit are that same quantity as `$12.50 of $40.00`,
  with no meter;
- other budget windows that also have an absolute remaining amount as `71% · $3.75`;
- percent-only windows as `71%`;
- balance-only windows as `$12.34` (or the unit amount) under a **Balance** title when the
  collector titled them Balance; **Reset Credits** keeps its title;
- one meter per quota window when a percent is meaningful;
- reset time as quiet metadata, in the shared reset copy; it does not imply the window period.

An Overview row spends no line on which source answered or how old its reading is. A reading that
no longer describes live quota says so in tone — muted value, meter at reduced opacity — and the
sentence that tone replaces is what VoiceOver announces for the row: the account, the source
display name, and the shared freshness line (`Account: pe***@example.com. Studio Mac. Updated 3m
ago`). Tone alone never carries the state. The Agents provider page keeps the per-source
freshness lines, because that page is where provenance is the subject.

Cursor's Other Models percentage and its included-usage dollar balance are related provider data but
not the same meter. Overview shows only the Other Models percentage. Keep the dollar remaining and
limit in the typed snapshot for a future provider-detail design; do not append them to the Overview
value or add a third Overview quota row.

Expired `valid_until` and explicit stale status use stale presentation. A provider authentication
failure is a setup task, not a generic network error. Never display collector raw output.

Overview asks how much is left, and a row another device's reading fills has answered it. This
Mac's own failed collection then stays off the row — it is the provider detail page's and
Diagnostics' subject — and the row shows the other device's reading alone. The failure shows on the
row only when this Mac's own reading is the one on it, where it says why that reading stopped
moving, or when there is no reading to show at all.

An account device's reading names why it is not current rather than only that it is not, in the
shared freshness words: **Sign-in needed**, **Unavailable**, **Unsupported**, **Can’t refresh** for
a state its own device reported, and **Not current** for a reading that merely aged past
`valid_until`. Those words are the row's spoken label and the provider detail page; the numbers stay
on screen either way, because they remain the last known reading.

Empty Overview recovery says to sign in to a provider CLI or enable an agent in Settings. A failed
current sync keeps last-known content visible and adds one inline warning.

### Cache rebuild

The service owns local storage. QuotaBar only presents `get_state.cache`.

While `cache.rebuilding` is true, Overview shows one inline notice at the top: **Usage history is
catching up** with **Quota and Account stay available.** Everything else stays exactly as it is —
navigation, Quota, Account, and Usage are unaffected, there is no progress to watch, and there is
no action to offer, because the next scan finishes it. Nothing blocks Quit: quitting sends the
service its `shutdown` and waits at most two seconds for the answer before going ahead without it.

### Settings

The Settings pages are the Settings group of the main window: **Account**, **Agents**,
**Notifications**, **Menu Bar**, **General**, and **Support**. The panel does not push Settings
pages; **Settings…** is an overflow-menu item on Overview. Account, Notifications, General,
Support, and Menu Bar stay grouped `Form`s; they do not paint an opaque page background over the
window. Each of those pages' content is at most 720pt wide and centred in the detail column.

The Account page is one Form in every state:

- Signed out or not checked: **Sign In**.
- Login running: **Finish sign-in in browser** with **Copy Link** and **Cancel**.
  Cancellation sends the typed service operation and closes the browser flow. Copy Link puts the
  authorize URL on the pasteboard. If QuotaBar could not open the browser, the page stays in this
  state and the error reads **QuotaBar could not open your browser. Copy the sign-in link and open
  it yourself.**
- Signed in: the account label, a Devices table on this same page, **Open quota.gotry.io**, and
  **Sign Out**.
- Logout pending: **Retry Logout**.
- Removed or expired device session: use the same **Sign In** action and never show raw reason codes
  or ids. Authentication-provider choice belongs to the login flow, not this row's label.

The Account page is the only place for account authentication actions. Buttons invoke typed private
service operations; there are no embedded web views.

Usage lives on the main window Usage page, reached from the footer **Today · $x** button. The Usage
root summary uses account-wide totals while signed in with Usage sync enabled, and local totals
otherwise.

**General** is a Settings-group page: **Launch at Login**, **Open window at launch** (toggle,
default off; hint **Show the QuotaBar window when you open the app**), **Show in Dock** (toggle,
default off; hint **Keep QuotaBar in the Dock when its window is closed**; off is menu-bar-only
except while the main window is open), **Refresh Interval** (Picker, 1, 2, 5, 10,
or 15 minutes, default 5, applies immediately), **Upload Usage to Account** (the existing
`usageUploadEnabled` switch), **Group Usage by project**, and **Reset Local Data**. Refresh Interval
is how often this Mac collects provider quota; Account summary still polls every minute, and a
window reset can collect quota once before the next interval. Reset Local Data always confirms first
and says plainly that collected quota and Usage history are deleted and rebuilt and that the person
stays signed in. That confirmation is a system dialog on the main window.

Support is a Settings-group page, and it asks the service nothing on its own: opening it starts no check
and costs no refresh. **Help** contains **Feedback**. **About** stays with Website, version, and
**Updates**, which opens Sparkle's standard updater; Sparkle also checks on a daily schedule after
launch.

Diagnostics is a disclosure on Support, not a separate page. Expanding it runs the private
`diagnose` operation on demand. It opens with the report's status line: a semantic icon, **All
systems working** / **Some checks need attention** / **Action needed**, and a fixed locale-shortened
evaluation time (`Checked 3:40 PM`), not relative age. Recheck lives in that disclosure once a
report exists; it starts or joins the real private-service refresh and waits for a newer evaluation.
While checking, Recheck becomes a small spinner and is disabled. If the bounded UI wait ends first,
keep the prior completed report on screen.

**Data** contains Quota Overview, This Mac Usage, Account Usage, and Account only, in that order.
**Sources** follows it and appears only when the service sent any: one row per provider, Usage
agent, or service-owned path, titled by provider or agent display name and the rung that answered.
Every subtitle on both lists is the sentence the service wrote — never a raw state word, a wire
code, or a metric key — and each row carries a semantic icon (accent check, grey inactive dash,
orange warning, red blocked mark).

**Report** follows with **Copy Report**, which writes the human-readable text report, including the
recent work the page does not list, and whose row title becomes **Report Copied** for about two
seconds. It lives here rather than on Support because here is where the report exists.

The first expand uses a Loading state. Its failure uses an Error state with **Retry** as the only
recovery action. A later Recheck preserves the last completed report; failure adds a fixed inline
warning above the report instead of replacing it and enables Recheck again. The Usage source control
is not repeated in Settings. **Show in Overview** remains presentation-only and has no diagnostic or
local-collection meaning.

Page navigation animates an immutable presentation snapshot. Async work and model updates continue
during the transition, while the shared page host coalesces presentation changes and publishes only
the latest state after the navigation animation is removed. Any page that can replace loading,
empty, error, or content at its root uses this host; individual pages must not delay requests or
guess the navigation duration. Header actions stay hidden during the transition and then reflect the
published page state. Reduce Motion skips the transition and publishes updates immediately.

### Menu Bar

**Menu Bar** is one form. A preview row above **Style** sits in its own grouped card: the
status-item label is centred on a simulated menu-bar strip (system material, 24pt tall) so the
preview looks like the bar. The label is drawn from `MenuBarLabelModel` for the current readings.
**Style** is a Picker over every
`MenuBarStylePreference` — segmented when there are four or fewer options, otherwise a menu.
**Provider** is an **Automatic** toggle; when it is off, a checklist of the providers Overview is
showing, in Overview's order, each with its catalog brand mark. Automatic is exclusive with the
named set. When two or more are named, **Combined** and **Separate** appear as a segmented control;
Combined is unavailable past three. **Reset time** is a Picker: **Relative** (`Resets in 3h 12m`) or
**Absolute** (`Resets Mon 17:12`). **Show pace lines** is a toggle, on by default. Every control
writes the existing storage keys and takes effect immediately.

### Notifications

Notifications is a Settings-group page. It holds the local remaining-quota rules this Mac evaluates
itself: one master switch, remaining-percent thresholds on each subscription Overview is showing,
and a switch for window-reset reminders.

- The master switch is off until the person turns it on and macOS grants alerts and sound. Turning
  it on asks `UNUserNotificationCenter` for `.alert` and `.sound`. A refusal puts the switch back
  to off and shows **Allow notifications for QuotaBar in System Settings.** with **Open System
  Settings**, which opens `x-apple.systempreferences:com.apple.Notifications-Settings.extension`.
  Opening the page re-reads the system permission; a later grant in System Settings does not turn
  the switch on by itself.
- Each visible subscription is one group: the catalog `display_name` and the masked account label.
  Two pickers choose remaining percent from **5 / 10 / 15 / 20 / 25 / 30 / 40 / 50**. The first
  defaults to **20**; the second defaults to **10** and may be **Off**, which stores a single
  threshold. Stored values stay descending and unique.
- Reset reminders default on. QuotaBar books a calendar notification at each available
  subscription's primary window `resets_at` and replaces it when a new reading arrives. Signing out
  or turning the master switch off removes every pending reminder. A `windowReset` the evaluator
  emits for a window that already has a reminder is left to that reminder.
- The page footer is **Quota reminds you when a refresh brings new data.** Quota does not promise
  real-time.
- Delivery is native.

The page is a grouped Form on the main window.

### Account

The Account page is always reachable from the sidebar. Signed out, it is **Sign In**. Signed
in, it holds everything that belongs to the account, top to bottom: the account label, **Devices**
as a section on this same page, **Open quota.gotry.io**, and **Sign Out**. **Upload Usage to
Account** lives on General — it is the same `usageUploadEnabled` switch, moved because it is a Mac
preference as well as account data. Multi-device sync is free for every account, so the page states
nothing about paying for it and the switch is bound by nothing but being signed in.

**Sign Out** is the one destructive row and it opens a window confirmation dialog with **Cancel**
and destructive **Sign Out** actions stating that the remote Device and synced data remain. Signing
out leaves this page on **Sign In**, because there is no longer an account to manage.

### Devices

Devices is a section on the Account page, not a sub-page. Each row is the device display
name, last seen as the shared freshness line (`last reading 5m ago`, or `no readings yet`), a
**This Mac** marker when the row is this installation, and **Remove**. Never a claim that a sleeping
or closed app is broken. Signed-out remains explicit. Never display raw Device IDs or request a
provider login for another Device. **Remove** confirms and then opens `quota.gotry.io/my/devices`,
where Device deletion lives. Empty and signed-out states stay on this page with Sign In. An
unavailable account with no device content offers Retry.

### Agents

Agents is a two-column page in the Settings group of the main window. A 1pt hairline with 24pt
gutters on each side divides the columns. The left column lists every catalog provider in
**Shown in Overview** and **Hidden from Overview** groups, each a `quotaCardSurface()` card.
Shown providers support drag reordering
and VoiceOver Move Up/Move Down actions. Every row carries one status line under the name. When
this Mac has a last-good official status-page reading, that line is **All systems operational**, or
**Degraded ·** the status-page description for `minor` and above. Otherwise it is
`SignInRungPresentation.statusLine`: **Signed in** (· *n* **accounts** when more than one),
**Configured**, **Reported by another device**, **Key rejected**, **Unavailable**, **Not
configured**, or **Not signed in** — so the list says which agent needs attention before it is
selected. Selecting a row shows that provider in the right pane. The sidebar **Agents** row
trails **3 shown** and, when any shown agent has no working credential and no device reporting it,
**· 1 needs sign-in**.

**Group Usage by project** lives on General, not here.

The right pane keeps grouped section chrome. It is that provider's settings, read top to bottom as
three questions — is it shown, what is it reporting, how does this Mac sign in — and contains
exactly these sections, in this order:

- **Overview**: one **Show in Overview** switch, no subtitle. Visibility is provider-wide and
  presentation-only.
- **Accounts**: one group for every subscription. Each account is a bold row inside the group —
  the masked account label, or **Account 1**, **Account 2** when there is no label, so two
  accounts cannot share a blank name — with the compact source menu as that row's trailing
  control; its sources follow as indented rows, and a hairline separates one
  account from the next. The menu uses `fieldFill` on the 24pt compact surface
  (`headerControlSurfaceSize`) inside a 28pt pointer target, like header icon actions, and reads
  **Automatic** or **Show: <source>** when pinned, then a small `chevron.down` at affordance
  size. It opens an app-owned floating menu (`quotaFloatingSurface`), not a
  system Menu. Choice rows use `fieldMinHeight` (32pt); the first item is **Automatic** with
  the quiet line **Newest live reading** under it, the rest are the available sources with no
  subtitle and no leading icons; the accent checkmark after the title is the only selected mark.
  Escape or a click outside the trigger and list dismisses it. VoiceOver names the control
  **Show from** and states the mode (Automatic or Pinned), the source Overview is actually
  showing, and the freshness. Source rows select which source's **Quota** section is shown —
  device icon, name, the shared freshness line trailing — and never pin. The source Overview is
  actually showing uses a filled device icon in accent; other devices stay outline in body.
  VoiceOver adds **Showing on Overview**. A pin whose source has gone is dropped and Automatic
  resumes. With no subscription yet the group holds one line: **No readings yet. Sign in below to
  start reporting.**
- **Source**: an inline **Quota** section, not a pushed page. It states freshness, then that
  source's remaining-quota windows. It does not repeat the source name, source type, account
  label, or plan. If the snapshot is not yet available it keeps the freshness line and does not
  invent empty quota. If the source has gone: **This source is no longer reporting.** There is no
  **Use this source** action; selection stays on the provider page menu. Source rows in
  **Accounts** select which source's quota is shown here.
- **Sign-in**: one group listing every credential rung this Mac has for the provider, in the
  order collection tries them, each with the verdict the last collection reached. Rung rows
  are `SignInRungPresentation`'s: **Codex CLI** / **Claude Code CLI** / **Grok CLI** /
  **Kimi Code CLI** (`terminal`), **API Key** (`key`, status only — the form is the **API Key**
  section below), **Cursor App** (`macwindow`), and **Browser Sign-in** (`safari`, a switch). The trailing
  status word is **Signed in**, **Configured**, or **On** in accent; **Not signed in**, **Not
  configured**, or **Rejected** in warning; **Unavailable** in body with the collection message
  as the subtitle. A CLI rung that is not signed in shows the catalog-provided copyable command
  as an indented `QuotaCommandRow` under it; a signed-in one shows no command. Kimi's key and
  CLI-file rungs answer the report by different source ids (`kimi_code_usages_api`,
  `kimi_code_cli_credential`), so each row carries its own verdict. Cursor is catalog
  `exclusive`: it has no command row, and its first rung is the Cursor.app session.
- **API Key**: an inline section for the providers with a key rung — native secure entry, optional
  base URL when catalog-enabled, the masked saved state, Save, and Remove. Not a pushed page. The
  Sign-in row shows the masked key and status only.
- **Browser Sign-in** is a rung row, not its own section: the switch's subtitle says what it
  is a fallback for while off (**Fallback when the CLI is signed out**), then **Looking for
  sign-ins…**, the accounts found, or where it looked and did not find one — **No sign-in in
  Chrome · Safari not checked** — so a browser that was read and held nothing never reads as
  one that was never opened. Off means QuotaBar does not
  read cookie jars. On asks for consent, then scans every allowed browser when this Mac has no
  usable official credential, and stores every validated session. A read macOS refused is its
  own line under the row, carried by `exclamationmark.triangle` rather than the generic
  `exclamationmark.circle`, and it replaces the ordinary error line rather than stacking with
  it.

Turning Browser Sign-in on uses an app-owned confirmation sheet on the main window, never a
system alert and never an overlay sized for the panel. There is no browser picker, account picker,
Sign In, or Disconnect. The sheet owns focus, Escape, keyboard, and VoiceOver while the main
window underneath is blocked. The sheet sits on the main window; the Browser Access grant
window keeps level `.floating` so it sits above it, and `keychainPromptBrowser` prompts still
fire.

After consent, QuotaBar preflights the browsers installed on this Mac and only then reads jars
it is already allowed to open. Whatever is still missing opens the **Browser Access** window —
a floating window rather than a page in the menu extra, because the extra closes on the click
in System Settings that Full Disk Access needs, and the QuotaBar icon has to be dragged from
somewhere that stays open. The window activates QuotaBar so it takes keyboard focus; Escape and
⌘W close it; it keeps the place the person last put it and never moves itself. It lists every
installed browser QuotaBar could read, one row each, with the browser's own icon, what stands in
front of its cookies, and at most one action: **Open Settings…** on Safari without Full Disk
Access, **Allow…** on a Chrome-family browser whose Keychain item still needs Always Allow
(disabled with a spinner while the system prompt is up), **Ready** with an accent checkmark on a
browser that can be read, and **Not set up yet** on a Chrome-family browser that has not created
its Keychain item. Firefox is listed as **Ready** with **No permission needed**. While Safari
needs Full Disk Access the window also holds a guidance block whose copy leads with turning on
the switch beside QuotaBar — the read macOS refused during the probe already lists the app there,
unchecked — and offers the icon to drag in only for the case it is not listed yet. That drag is a
plain file drag of QuotaBar.app, on the pasteboard from the first pixel; it starts after a 4pt
threshold, ignores modifier keys, brings System Settings forward first so the list is the window
under the cursor, and a drop accepted with System Settings in front moves to the relaunch step
exactly as **Open Settings…** does. After **Open Settings…** the window adds one more row,
**Relaunch QuotaBar**, whose copy says to relaunch once QuotaBar is in the list — never that the
grant is already on, which this process cannot know. The window closes on its own when nothing is
outstanding. Dismissing it leaves Browser Sign-in on.

On the Agents page the outstanding grants are one indented destination row under the switch —
**Browser Access** with a one-line summary such as **Safari and Chrome need permission** or
**Relaunch QuotaBar to finish granting Full Disk Access** — that opens the window; there are no
per-browser rows or action labels on the Agents page. The row disappears when every installed
browser is readable.
Scheduled refreshes never prompt: they skip Safari without Full Disk Access and any Chrome-family
browser whose Keychain ACL is not already allowed, and record each as a refusal.

**Consent copy.** Reading another program's cookie jar is the one thing this app does that a person
has to agree to, so turning **Browser Sign-in** on states what is about to happen before any store
is opened. Cancel and Escape read nothing. The message is two sentences: that QuotaBar will read
that provider's sign-in cookies — the cookie names and hosts, both quoted from the catalog — that
browsers on this Mac hold; and that accepted sessions stay in QuotaBar's local service database
until the scan is turned off and are never uploaded. It does not list macOS permissions: which one
each browser needs is only known per installed browser, and the Browser Access window says it
there. Confirm reads **Read Cookies**, never "OK" or "Allow".

**Refusal copy.** A store macOS would not open is a different state from finding no session, and it
never reads as one. Each refusal names the browser and the single next action — grant Full Disk
Access, allow the Keychain item, or quit the browser and retry — and never a store path, a profile
name, or the underlying error's text. The scan continues with the other browsers.

QuotaBar never reads provider credential files. New values travel only over private child stdin and
Swift clears the field after Save; the service owns validation, owner-only persistence, and masking.

## Desktop widgets

QuotaBar embeds `PlugIns/QuotaBarWidgets.appex`. The widgets read the same non-secret
`WidgetSnapshot` as iOS ([ADR 0014](../../docs/decisions/0014-nonsecret-ios-widget-snapshot.md)),
from QuotaBar's own App Group `86Y537ZF24.group.io.gotry.quota`, and never talk to Relay or the
private service. QuotaBar publishes it after every state update from the Overview rows already on
screen, and clears it when there is nothing to show.

| Kind | Families | Content |
| --- | --- | --- |
| Overview | systemSmall, systemMedium, systemLarge | Remaining quota across the most constrained subscriptions, reset, **Updated** age, and Today's tokens and API-equivalent cost |

The views are the phone's: one `QuotaWidgetViews` package draws both platforms
([ADR 0043](../../docs/decisions/0043-one-widget-view-package-for-both-platforms.md)), so Home
Screen remaining figures follow the same information order, the same ranking, and the same **Updated**
phrase as iOS. A carried `pace` of `runs_out` uses the existing warning color; no pace means no
extra color.

Links follow the iPhone's rule. QuotaBar registers the `quotabar:` scheme and answers
`quotabar:/overview` and `quotabar:/subscriptions/<selection_id>`; either opens the panel from the
first status item, and a subscription lands on that provider's read-only quota page. A link whose
`selection_id` this installation never published — an older salt, a provider since removed —
lands on Overview rather than nothing. Medium and large rows are each a `Link` to their own
subscription; the widget as a whole opens the subscription it shows, or Overview when it shows
several. `quotabar://dashboard` opens the main window on Quota; widgets do not publish it.

The meter is the product accent, from the extension's own `AccentColor` asset catalog — the
extension has no app to borrow a tint from.

Two things differ from the phone, and only these two:

- **No Lock Screen.** The desktop offers small, medium, and large; the accessory families stay iPhone's.
- **The meter is drawn with SwiftUI shapes**, not `Gauge`, which on macOS is an AppKit-backed
  control a widget's archived view tree cannot draw.

An ad-hoc signed local package is not entitled to the App Group, so it publishes nothing. That is
not a failure the panel reports: Diagnostics' **Data** section carries a **Desktop Widgets** row
whose sentence says whether a snapshot was published, cleared, refused, or is simply off.

## Shared components

| Component | Contract |
| --- | --- |
| `MenuBarShell` | Fixed header/body/footer geometry |
| `MenuBarHeader` | Back/title/root actions and keyboard-safe transient menu |
| `SettingsSection` | Quiet label, optional trailing control, plus group (`quotaGroupSurface`) or card (`quotaCardSurface`) chrome |
| `SettingsListRow` | Shared icon/title/subtitle/trailing alignment |
| `QuotaCommandRow` | Selectable official-provider sign-in command and Copy/Copied feedback |
| `QuotaConfirmationPopup` | App-owned confirmation with cancel and destructive actions. Overlay (scrimmed) in the menu panel; sheet on the main window for Browser Sign-in consent |
| Browser Access window | Floating window independent of the menu extra and above the main window; one row per installed browser with its icon, gatekeeper, and single action; Relaunch row after the Full Disk Access pane was opened; closes itself when nothing is outstanding |
| Main window | Titled window, 960×640 minimum, 220–280pt sidebar of Quota and Settings groups; Quota / Today / Usage cards, and Settings pages |
| Full Disk Access drag icon | App icon inside the Browser Access window; a plain file drag of QuotaBar.app for the Full Disk Access list, activating System Settings first and reporting an accepted drop |
| `QuotaPrimaryButtonStyle` | Accent capsule for the one primary task on a surface |
| `QuotaSecondaryButtonStyle` | Compact field-height control for secondary or destructive in-section actions |
| `QuotaListRowButtonStyle` | Nested hover/press feedback with full-row hit target |
| `ProviderBrandIcon` | Catalog brand resource with stable optical sizing |
| `QuotaPageStateView` | Centered Loading, Empty, or Error when no page content is available |
| `QuotaInlineNotice` | Compact refresh/error warning while cached content remains visible |
| `CacheRebuildNotice` | Inline notice while local Usage history is being rebuilt |
| `QuotaSectionStateView` | Left-aligned Loading, Empty, or Error scoped to one section |

Prefer these components over page-local replicas. In-section actions never mix an accent capsule
with a system or bordered control. **Save** and empty-state **Retry** use compact primary.
**Remove** uses secondary with the destructive variant. Browser Session is a **Browser Sign-in**
switch, not a pair of in-section actions. Diagnostics' Recheck is a header icon action only; Copy Report and
Reset Local Data are Settings list rows. Full-width Settings rows such as **Sign Out** stay list rows. Do not use
`ButtonStyle.bordered` or an unstyled system button inside the panel. Provider assets remain in
`QuotaBrandIcons`; do not copy their geometry into SwiftUI paths.

Page states live outside `ScrollView`, fill the entire body between the normal header and footer,
and center their content horizontally and vertically. Loading is a small spinner plus a short title.
Empty uses a neutral icon, title, explanation, and at most one action. Error uses a critical icon,
title, explanation, and one central **Retry**. The header never renders loading or failure copy and
does not gain recovery controls for a full-page state. If useful content exists, keep it visible and
use `QuotaInlineNotice`; if only one section lacks content, use `QuotaSectionStateView`. These views
share tokens and accessibility semantics but do not own tasks or form a generic async state machine.

## Accessibility and input

- Every icon-only button has an accessibility label and Help tooltip.
- Diagnostics' Recheck header icon announces **Recheck**, or **Checking** while a check runs.
  Copy Report announces **Copy report**, then **Report copied**; Reset Local Data announces what it
  deletes. The status line VoiceOver label includes the fixed check time. Data and Sources status
  icons use distinct shapes and announce Working, Needs attention, Unavailable, or Off, and each row
  announces the service's own sentence rather than a wire code.
- Rows combine or replace child accessibility deliberately; never announce raw opaque identifiers.
- Disclosure rows announce their destination and current summary.
- Login exposes a real Cancel action while the service's browser flow runs.
- Drag reordering has Move Up and Move Down accessibility actions.
- Focus rings use the native/accent treatment and are never suppressed on editable controls.
- Large text may increase content height; ScrollView must retain access to every row.
- Do not rely on color alone for stale, partial, unavailable, or signed-out state.

## Visual QA matrix

Required fixture states are loading, signed-in content, cached content with a sync warning,
signed-out provider issues, service unavailable, and a rebuilding cache (`cache-rebuilding`).

Every `--route` below is inspected in `--appearance light` and `dark`, and at `--text-size
standard` and `accessibility` (60 cells, plus `main-quota` at 1280×800). `--text-size extra-large`
is available on the visual app for spot checks. Keyboard traversal, VoiceOver labels, and Reduce
Motion are inspected on the same routes. CI's `verify` job on macos-26 uploads the rendered
matrix as the `quotabar-visual-matrix` artifact. Liquid Glass renders only on that runner; a Mac
on 14 or 15 produces the same routes with the material fallback.

| `--route` | Surface | Size | Appearances | Text sizes |
| --- | --- | ---: | --- | --- |
| `overview` | Panel | 320×480 | light, dark | standard, accessibility |
| `provider-codex` | Panel | 320×480 | light, dark | standard, accessibility |
| `main-quota` | Main window | 960×640 and 1280×800 | light, dark | standard, accessibility |
| `main-quota-codex` | Main window | 960×640 | light, dark | standard, accessibility |
| `main-today` | Main window | 960×640 | light, dark | standard, accessibility |
| `main-usage` | Main window | 960×2200 | light, dark | standard, accessibility |
| `main-usage-local` | Main window | 960×2200 | light, dark | standard, accessibility |
| `main-account` | Main window | 960×640 | light, dark | standard, accessibility |
| `main-agents` | Main window | 960×640 | light, dark | standard, accessibility |
| `main-agents-codex` | Main window | 960×640 | light, dark | standard, accessibility |
| `main-agents-litellm-key` | Main window | 960×640 | light, dark | standard, accessibility |
| `main-notifications` | Main window | 960×640 | light, dark | standard, accessibility |
| `main-menu-bar` | Main window | 960×640 | light, dark | standard, accessibility |
| `main-general` | Main window | 960×640 | light, dark | standard, accessibility |
| `main-support` | Main window | 960×640 | light, dark | standard, accessibility |

Synthetic fixtures may contain display labels and opaque ids needed for typed models, but must never
contain access tokens, refresh tokens, provider secrets, or raw production data.
