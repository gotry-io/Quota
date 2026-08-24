# QuotaBar Menu Panel Design

This file is the canonical visual and interaction specification for the native macOS QuotaBar menu
panel. Website marketing UI belongs in `apps/web/DESIGN.md`.

## Product character

QuotaBar should feel like a precise macOS instrument: compact, calm, legible, and immediately useful.
It uses system materials and controls, a restrained blue accent, and dense information hierarchy.
The panel is an app-owned SwiftUI surface, not a website compressed into a popover.

Core rules:

1. Remaining quota is the primary value. Usage and account state support it without competing.
2. One header, one footer, and one typed navigation stack are shared by every page.
3. Account actions are plain user tasks: continue with GitHub, inspect devices, inspect Usage, log
   out.
4. QuotaBar displays typed local-service results. Provider configuration exposes only intentional
   API-key entry and masked saved state, never stored secrets, opaque account identifiers, or raw
   diagnostics.
5. Every action remains keyboard reachable, VoiceOver labelled, and usable with Reduce Motion and
   large text.

## Window and layout tokens

| Token | Value | Purpose |
| --- | ---: | --- |
| `panelWidth` | 320pt | Fixed menu-panel width |
| `panelMaxHeight` | 480pt | Shared fixed panel height |
| `panelHorizontalPadding` | 16pt | Header, content, and footer gutter |
| `pageVerticalPadding` | 16pt | Page content inset |
| `headerHeight` | 44pt | Navigation and title chrome |
| `footerHeight` | 36pt | Last-sync action |
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

Spacing uses 4, 6, 8, 12, and 16pt semantic steps. Avoid page-specific magic numbers. Scroll only the
page body; header and footer remain fixed. Content aligns to the same 16pt guide at every depth.

## Material and color

Production inherits the menu extra's system material. Add only adaptive semantic layers:

- Panel: transparent material plus `panelWash`.
- Group: `settingsGroupFill` with a continuous 10pt silhouette.
- Control: `fieldFill`, with `fieldFillFocused` and the accent focus ring.
- Transient: regular material plus `floatingMenuFill`, a 0.5pt adaptive edge, and restrained shadow.
- Hover/press: `rowHoverFill` and `rowPressedFill` nested inside the group.

Use `QuotaPalette` roles instead of fixed RGB values. `ink` is for primary text and marks, `body` for
supporting copy, `mute` for tertiary metadata, `accent` for primary action/focus/progress, and
`critical` only for failure or destructive meaning. Native system red remains the destructive color.

Do not add decorative gradients, oversized cards, colored page backgrounds, or custom window chrome.

## Typography

Use semantic roles from `QuotaDesign.Typography`:

| Role | Size/weight | Use |
| --- | --- | --- |
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

Dynamic Type scales semantic text roles. Utility symbols keep their optical sizes, while their hit
targets stay at least 28pt. Technical strings and chevrons never receive primary-text emphasis.

## Shell

The header shows:

- Overview: Quota mark, **QuotaBar**, and Settings gear.
- Child page: Back and page title. Usage may place its Account/This Mac source menu at the trailing
  edge because the choice changes the whole page. Diagnostics places icon-only **Recheck**
  (`arrow.clockwise`) then **Copy** (`doc.on.doc`) actions there only after a report exists; initial
  loading and full-page failure leave the header action area empty. Recheck starts or joins the real
  private-service refresh and waits for a newer completed diagnostic revision; while checking, its
  icon becomes a small spinner and the action is disabled. If the bounded UI wait ends first, show
  that refresh is still running and keep the prior completed snapshot. Copy writes the human-readable
  text report, shows a `checkmark` for about two seconds after success, and remains available while an
  existing report is rechecked.
- Settings root: Back, **Settings**, and an overflow menu containing **Quit QuotaBar**.

The footer is a single quiet button showing the sync-completion clock as locale-shortened time only
(`15:40` / `3:40 PM`), or **—** before any sync. VoiceOver still says **Last checked** plus that
time. It is not the age of every provider observation. Selecting it runs one sync; clicks while a
sync is active are ignored.

Navigation transitions move horizontally by direction and combine with opacity. Reduce Motion uses
opacity only. A page change clears transient focus/menu state. Escape dismisses a transient menu;
Back returns one level.

## Information architecture

```text
Overview
└── Settings
    ├── Devices
    ├── Usage
    ├── Diagnostics
    └── Agents
        └── Provider
```

### Overview

Render the service-provided Overview in saved catalog order. Each provider row may contain multiple
account observations; Rust has already merged global identities and selected one freshest valid
observation. Swift never repeats that policy. Never add or average percentages across devices.

Overview shows quota only. Usage totals, models, messages, and cost remain on the Usage detail page in
Settings and never create or extend an Overview provider group.

Each quota observation shows:

- provider brand and name;
- optional masked account label and normalized plan badge;
- remaining value as the strongest number, with no "left" or "remaining" suffix;
- budget windows that also have an absolute remaining amount as `71% · $3.75`;
- percent-only windows as `71%`;
- balance-only windows as `$12.34` (or the unit amount) under a **Balance** title;
- one meter per quota window when a percent is meaningful;
- reset time, stale state, and selected source display name as quiet metadata. Reset copy uses
  weekday and time within six days, otherwise month and day; it does not imply the window period;
- **Local** for signed-out local collection or **Device** for an account observation.

Cursor's Other Models percentage and its included-usage dollar balance are related provider data but
not the same meter. Overview shows only the Other Models percentage. Keep the dollar remaining and
limit in the typed snapshot for a future provider-detail design; do not append them to the Overview
value or add a third Overview quota row.

Expired `valid_until` and explicit stale status use stale presentation. A provider authentication
failure is a setup task, not a generic network error. Never display collector raw output.

A local collection failure is about this Mac, so an account device's reading fills the row without
hiding it: the row shows both. A provider this Mac never set up reports no discovered source and
stays quiet once the account covers it, because there is nothing here to recover.

An account device's reading names why it is not current rather than only that it is not: **Sign-in
needed**, **Unavailable**, **Unsupported**, **Can’t refresh** for a state its own device reported,
and **Stale** for a reading that merely aged past `valid_until`. The numbers stay on screen with
their age, because they remain the last known reading.

Empty Overview recovery says to sign in to a provider CLI or enable an agent in Settings. A failed
current sync keeps last-known content visible and adds one inline warning.

### Repair

The service owns repair. QuotaBar only presents `get_state.repair`. There is no Settings **Repair**
button and no `doctor --repair` action.

`repair.severity` chooses the surface:

- `durable` with status `repairing`, `stuck`, `failed`, or the short `completed` flash: a full Repair
  page overlay. Header title is **Repairing**, **Repair stopped**, or **Repair failed**. There is no
  back, Settings, Diagnostics, Account, Usage, or Agents. Opening the menu extra shows this page.
  Content is the service `title`, `activity`, elapsed time from `started_at`, heartbeat age when
  `now - heartbeat_at > 8s` (**Updated 12 seconds ago**), a determinate bar only when both progress
  fields are present (otherwise a spinner), then `guidance`. Stuck and failed add a critical icon and
  one **Retry** or reinstall copy.
- `derived`: Overview and Usage stay. One inline notice uses `title` + `activity` + optional bar.
  Navigation remains. Quit is not intercepted.
- `checking` and `idle`: Overview. `checking` lasts at most two seconds and does not open Repair.

`applicationShouldTerminate` returns `.terminateCancel` only while `repair.blocks_quit` (durable
repairing). It opens the Repair page and announces **QuotaBar is repairing local data. Keep the app
open.** Sparkle is suppressed only while `blocks_quit`. Closing the menu extra never cancels repair.

### Settings

Settings section order is fixed:

1. **Account**
2. **Quota**
3. **General**

Account states:

- Signed out or not checked: the Account group contains only one standard-height **Sign In** row.
- Login running: one standard-height browser completion row with **Cancel**. Cancellation sends the
  typed service operation and closes the browser flow.
- Signed in: the Account group contains the account row followed by **Devices**. Clicking the account
  row opens the web account surface. A separate **Log Out** row sits at the bottom of the Settings
  page, after every group. It opens an app-owned confirmation popup with **Cancel** and destructive
  **Log Out** actions; it states that the remote Device and synced data remain. Do not use a system
  alert for this flow.
- Logout pending: one standard-height status row with **Retry Logout**.
- Removed or expired device session: use the same **Sign In** action and never show raw reason codes
  or ids. Authentication-provider choice belongs to the login flow, not this row's label.

The Account group is the only place for account authentication actions. Buttons invoke typed private
service operations; there are no embedded web views.
Do not add a separate account-management row; the signed-in account label is that destination.

Quota contains the **Usage** and **Agents** destinations. The Usage root summary uses account-wide
totals while signed in with Usage sync enabled, and local totals otherwise. General contains the
native mini **Launch at Login** and **Sync Usage** switches followed by the **Support** destination.
Support contains Diagnostics, Feedback, Website, version, and **Check for Updates**. That row
opens Sparkle's standard updater. Sparkle also checks on a daily schedule after launch. Diagnostics
remains backed by the private `diagnose` operation and shows the report's independent operation, data,
and attention result. **Findings** appear before **Data** in error, warning, then info order and explain
the root problem and next recovery step. **Data** contains Quota Overview, This Mac Usage, Account
Usage, and Account only; each row shows a concise user-facing summary and semantic icon (accent check,
orange warning, or red blocked mark), never a raw state word or metric key. Provider and agent source
checks remain in copied diagnostics rather than becoming another settings list. The report time is a
fixed locale-shortened completed-refresh time (`Checked 3:40 PM`), not relative age. A running refresh
adds **Refresh still running · showing the last completed check**. Recheck and Copy live only in the
page header; opening Diagnostics resets and requests a real refresh so re-entry never silently shows a
previous report. That initial check uses a centered page Loading state. Its failure uses a centered
Error state with **Retry** as the only recovery action and no header actions. A later Recheck preserves
the last completed report; failure adds a fixed inline warning above the report's scrolling content
instead of replacing the page, keeps Copy available, and enables Recheck again. The Usage source
control is not repeated in Settings. **Show in Overview** remains presentation-only and has no
diagnostic or local-collection meaning.

**Recent Activity** follows Data as a disclosure group. It renders the service-owned bounded attempt
projection with kind, trigger, source/subject, running/completed time, duration, typed outcome/code,
recovery, and bounded metrics. `running`, `interrupted`, `partial`, and normal `no_work` remain
visually distinct. A truncated-history note is informational. Copy includes the same attempts in
human-readable text and strict JSON; Swift does not reinterpret them.

Page navigation animates an immutable presentation snapshot. Async work and model updates continue
during the transition, while the shared page host coalesces presentation changes and publishes only
the latest state after the navigation animation is removed. Any page that can replace loading,
empty, error, or content at its root uses this host; individual pages must not delay requests or
guess the navigation duration. Header actions stay hidden during the transition and then reflect the
published page state. Reduce Motion skips the transition and publishes updates immediately.

### Devices

Devices is read-only in QuotaBar. Show account device display name, platform, app product/version,
and compact last report/refresh/sync age. A server-fresh report is **Healthy** only when operation is
healthy, data is current or empty, and attention is none or automatic. Other fresh problem states are
**Needs attention** or **Check device** and say **Review Diagnostics on this device**. An expired or
absent report is **Not recently active** or **Unknown**, never a claim that a sleeping or closed app
is broken. Signed-out remains explicit. Never display raw Device IDs or request a provider login for
another Device. Empty and signed-out states point back to the Account action in Settings using the
shared centered Empty state. An unavailable account with no device content uses the centered Error
state and Retry; a refresh warning with cached device content uses an inline notice. Device deletion
and account administration live on the Web account surface.

### Usage

Usage defaults to Account when an account summary is available and Usage sync is enabled; otherwise
it uses This Mac. The compact source menu is the Usage header's trailing action; its options are
simply **Account**, with a single-account symbol, and **This Mac**. Omit the menu when Account data is
unavailable or Usage sync is disabled; in those states the page is unambiguously local. Changing
source preserves the selected period.

A four-item 28pt tab control selects Today, 7 Days, 30 Days, or All; Today is the default. Its
labels use the regular 10.5pt list-secondary type size. The control owns one overall neutral
background, with the selected item highlighted inside it; do not wrap it in another group surface.
The selection is one inclusive date window from the service's precomputed snapshot. Opening Usage
and changing either selector never starts collection or network work and never shows a loading
state when a snapshot already exists. If the selected source has no snapshot yet and that
component is still refreshing, the page says **Preparing Usage…** instead of implying Usage is
absent. After refresh finishes with no snapshot, it says **No Usage is available for this period.**
Preparing and empty Usage remain section states below the period tabs because those controls are
still useful. Cached account refresh failures and partial Usage warnings are inline notices and do
not replace available content.
The default page contains:

- Summary: a titled group with separate Tokens and Cost headline metrics followed by the six token
  and message metrics in a two-column grid. Headline values use the primary text tone; grid labels
  stay muted while their values use the secondary tone.
- Models: grouped by inference provider, independent of the collecting client. Every model remains a
  static single row ending in `tokens · cost` when priced, or only `tokens` when unpriced.

Provider headings use the structured inference-provider brand mark; never infer an icon from model
text. Model rows have no repeated icon and align under the provider label. When no owned brand asset
exists, use an honest semantic system symbol rather than another provider's logo. Approved
monochrome brand assets come from the Lobe Icons source recorded in the bundled third-party notice.
Every provider, regardless of model count, uses the same separate noninteractive heading with a 14pt
provider icon. The Models surface has 8pt vertical insets, provider groups have 8pt between them, and
each heading has 4pt before its compact static model rows; model rows also have 4pt between them.
Model rows have no icons or disclosure controls and use regular secondary text. Each provider shows
at most the first five models in the existing cost/tokens order. If the same provider/model pair
appears through more than one client, append the client name only to disambiguate those rows.

Date text, cost metadata, pricing revision, and coverage are not separate default sections. Complete
data shows no diagnostic copy. Partial collection produces one compact warning. An unavailable
summary cost uses `— unpriced`, while model rows omit unavailable cost entirely; neither state adds
another alert. Technical detail remains available through Diagnostics.

Usage counts use locale-aware decimal formatting below 1,000 and compact SI-style `k`, `M`, and `B`
suffixes for larger values. Usage groups use priced-cost-first ordering, then fall back to tokens and
name for stability.

Compact cost copy is exact:

- complete: `$X`;
- partial: `≥ $X`;
- unavailable: `— unpriced`.

Do not infer missing prices, silently treat partial cost as total cost, or recompute typed output.
Summary and model values use two fractional digits to preserve the single-line layout.

### Agents

Agents has **Shown in Overview** and **Hidden from Overview** groups. Shown providers support drag
reordering and VoiceOver Move Up/Move Down actions. A quiet desktop symbol means an account device
has a presentable observation for that provider.

Provider detail contains:

- **Overview**: provider-wide visibility switch;
- **Reporting From**: This Mac or account device display names, source kind, optional stale state,
  and compact observation age;
- **This Mac Sign-in**: the catalog-provided copyable official-provider command, shown with Browser
  Session unless that session is catalog `exclusive` (Cursor); or
- **This Mac Configuration**: native secure API-key entry, optional base URL when catalog-enabled,
  masked saved state, Save, and Remove; and
- **Browser Session** when catalog-enabled: disconnected **Sign In**, bounded **Waiting / Cancel**,
  non-cancellable **Connecting** after commit begins, or a connected masked account with only
  **Disconnect**. Sign In, Cancel, and Disconnect are the same compact secondary control; do not
  use an accent capsule or explanatory body copy on this surface. Confirmed disconnect is likewise
  non-cancellable. There is no switch-account action; a different account is disconnect, then sign
  in.

Browser-session login uses app-owned selection/confirmation popups at the panel root, never system
alerts or sheets. Login is pinned to one supported browser; an unsupported default HTTPS handler
requires a browser selection before opening the URL. One unambiguous new account may commit
automatically; multiple accounts require selection. Lists scroll within the panel; the popup owns
focus, Escape, keyboard, and VoiceOver while the underlying page is disabled and accessibility-hidden.

QuotaBar never reads provider credential files. New values travel only over private child stdin and
Swift clears the field after Save; the service owns validation, owner-only persistence, and masking.

## Shared components

| Component | Contract |
| --- | --- |
| `MenuBarShell` | Fixed header/body/footer geometry |
| `MenuBarHeader` | Back/title/root actions and keyboard-safe transient menu |
| `SettingsSection` | Quiet label plus adaptive group surface |
| `SettingsListRow` | Shared icon/title/subtitle/trailing alignment |
| `QuotaCommandRow` | Selectable official-provider sign-in command and Copy/Copied feedback |
| `QuotaConfirmationPopup` | Scrimmed app-owned confirmation with cancel and destructive actions |
| `QuotaPrimaryButtonStyle` | Accent capsule for the one primary task on a surface |
| `QuotaSecondaryButtonStyle` | Compact field-height control for secondary or destructive in-section actions |
| `QuotaListRowButtonStyle` | Nested hover/press feedback with full-row hit target |
| `ProviderBrandIcon` | Catalog brand resource with stable optical sizing |
| `QuotaPageStateView` | Centered Loading, Empty, or Error when no page content is available |
| `QuotaInlineNotice` | Compact refresh/error warning while cached content remains visible |
| `RepairPageView` | Full durable-repair overlay; no navigation |
| `RepairDerivedNotice` | Inline derived-repair title, activity, and optional progress |
| `QuotaSectionStateView` | Left-aligned Loading, Empty, or Error scoped to one section |

Prefer these components over page-local replicas. In-section actions never mix an accent capsule
with a system or bordered control. **Save** and empty-state **Retry** use compact primary. Browser
Session **Sign In**, **Cancel**, **Remove**, and **Disconnect** use secondary; destructive labels
use the destructive variant. Diagnostics Recheck and Copy are header icon actions only, not
in-section buttons. Full-width Settings rows such as **Log Out** stay list rows. Do not use
`ButtonStyle.bordered` or an unstyled system button inside the panel. Provider assets remain in
`Resources/BrandIcons`; do not copy their geometry into SwiftUI paths.

Page states live outside `ScrollView`, fill the entire body between the normal header and footer,
and center their content horizontally and vertically. Loading is a small spinner plus a short title.
Empty uses a neutral icon, title, explanation, and at most one action. Error uses a critical icon,
title, explanation, and one central **Retry**. The header never renders loading or failure copy and
does not gain recovery controls for a full-page state. If useful content exists, keep it visible and
use `QuotaInlineNotice`; if only one section lacks content, use `QuotaSectionStateView`. These views
share tokens and accessibility semantics but do not own tasks or form a generic async state machine.

## Accessibility and input

- Every icon-only button has an accessibility label and Help tooltip.
- Diagnostics Recheck and Copy header icons announce their actions; Copy uses **Copy diagnostics**
  and **Diagnostics copied**. The status line VoiceOver label includes the fixed check time.
  Data status icons use distinct shapes and announce Working, Needs attention, or Unavailable;
  finding rows announce severity and recovery instructions without exposing wire codes.
- Rows combine or replace child accessibility deliberately; never announce raw opaque identifiers.
- Disclosure rows announce their destination and current summary.
- Login exposes a real Cancel action while the service's browser flow runs.
- Drag reordering has Move Up and Move Down accessibility actions.
- Focus rings use the native/accent treatment and are never suppressed on editable controls.
- Large text may increase content height; ScrollView must retain access to every row.
- Do not rely on color alone for stale, partial, unavailable, or signed-out state.

## Visual QA matrix

Required fixture states are loading, signed-in content, cached content with a sync warning,
signed-out provider issues, service unavailable, and Repair (`repairing-durable`,
`repairing-derived`, `stuck`, `failed`). Required routes are Overview, Settings, Agents, provider
setup variants (CLI, API key, and browser session), Devices, Usage, Diagnostics, and Repair. Inspect
light and dark appearances, standard and accessibility text sizes, keyboard traversal, VoiceOver
labels, and Reduce Motion transitions.

Synthetic fixtures may contain display labels and opaque ids needed for typed models, but must never
contain access tokens, refresh tokens, provider secrets, or raw production data.
