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
- **A window with no reported refill instant reads “No reset time reported.”** One phrase; a future
  reset instant still prints as a date or a countdown, because that is not an age.
- **Provider names come from the catalog.** `display_name` in `packages/provider/catalog.json` is
  the only place a provider is named for a person. No surface keeps a second table and none derives
  a name from an identifier.
- **A device row states one verdict and the one age it came from**: **Active** under thirty minutes,
  **Idle** up to a day, **Not reporting** beyond that, and `last reading 5m ago` from the instant
  that decided it. Never a list of report, refresh, and sync timestamps.
- **User-facing copy uses product words.** Nothing on screen names coverage, UTC hours, generations,
  revisions, fingerprints, sequences, protocol versions, or the private service's implementation.
  Counting how many readings came from this Mac and how many from the account is implementation
  detail; whether the numbers are still current is not. **This Mac** and **Account** remain valid as
  the two Usage sources a person picks between.

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

Spacing uses 4, 6, 8, 12, and 16pt semantic steps. Avoid page-specific magic numbers. Scroll only the
page body; header and footer remain fixed. Content aligns to the same 16pt guide at every depth.

## Material and color

Production inherits the menu extra's system material. Add only adaptive semantic layers:

- Panel: transparent material plus `panelWash`.
- Group: `settingsGroupFill` with a continuous 10pt silhouette.
- Control: `fieldFill` plus the accent focus ring.
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

## Menu bar item

The item is the product's first sentence: the tightest number is legible without opening anything.
It is a template mark plus the remaining percent of one current subscription. By default that is the
most constrained one — the smallest remaining percent across every window of every Overview reading
that still describes live quota. A reading the source reported as failed, or one the shared
freshness rule has aged out, answers for nothing. Balance-only windows have no budget to be a
percent of and never set it. Ageing out is a fact about the clock rather than about anything the
service says, so the item re-asks the question once a minute — the freshness rule's smallest
unit — and a Mac that stopped collecting loses its number without waiting for an event that is
never coming. The item is only rebuilt when that answer changed.

The mark and the number are composed into **one template image**, which is what the menu bar is
given. A status item is one image to AppKit, and AppKit places it exactly as it places every other
one; a stack of views asks two layout systems to agree about where a baseline is, and they do not.

The image is the standard status-item height — the bar's own thickness less the padding every item
leaves, which is 18pt in the 22pt bar macOS ships — drawn at 2× and marked template. The mark is the
brand of the provider the number belongs to, fitted **by its ink** into a 14.5pt square: catalog
assets fill their own viewBox by wildly different amounts, and matching the box instead of the ink
would make one provider's logo tower over another's, and all of them over the SF Symbol glyphs
beside them. Quota's own mark appears in exactly two places: the Icon style, which says nothing about
a provider, and an item with no current number to attribute.

The number follows 4pt after the mark, set in the **menu-bar font** with monospaced digits so the
item does not twitch as it moves, and its baseline is placed so the digits' cap-height middle is the
image's middle. A line box would center the room it reserves for descenders no digit uses, which is
how a number ends up riding high next to a mark. The status bar renders a template image, so low
quota cannot be said in color; below 10% remaining the text takes a `!` prefix.
`MenuBarLabelLayoutTests` renders the image and measures the drawn pixels: the mark's ink and the
digits' ink share a center within a quarter point, and every mark lands at the same size.

Settings → Menu Bar → **Style** chooses **Icon**, **Percent**, or **Icon and percent** (the default),
and → **Provider** chooses **Automatic** — the tightest current subscription — or one provider from
those Overview is showing. Both persist in UserDefaults. A chosen provider with no current
reading shows the mark alone and never borrows another provider's number, and **Percent** likewise
falls back to the mark alone when there is no percent to show, because an item with no content
cannot be clicked. VoiceOver announces **QuotaBar**, the provider the number belongs to, and the
remaining percent.

## Shell

The header shows:

- Overview: Quota mark, **QuotaBar**, and Settings gear.
- Child page: Back and page title. Usage may place its Account/This Mac source menu at the trailing
  edge because the choice changes the whole page. Diagnostics places one icon-only **Recheck**
  (`arrow.clockwise`) action there only after a report exists; initial loading and full-page failure
  leave the header action area empty. Recheck starts or joins the real private-service refresh and
  waits for a newer evaluation; while checking, its icon becomes a small spinner and the action is
  disabled. If the bounded UI wait ends first, keep the prior completed report on screen.
- Settings root: Back, **Settings**, and an overflow menu containing **Quit QuotaBar**.

The bottom bar is fixed at `footerHeight` on every page and carries two things: today's spend on
the left, and one icon-only refresh action on the right. The left reads `Today · $12.34 · 1.2M
tokens` from the Usage source the Usage page would show; cost drops out when the day is unpriced,
and the whole line is absent when there are no tokens. Today's number belongs beside quota
everywhere, so it lives in the bar every page already has rather than in an Overview line of its
own.

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
Overview
└── Settings
    ├── Account
    │   └── Devices
    ├── Usage
    ├── Menu Bar Style
    ├── Menu Bar Provider
    ├── Support
    │   └── Diagnostics
    └── Agents
        └── Provider
```

### Overview

Render the service-provided Overview in saved catalog order. Each provider row may contain multiple
account observations; Rust has already merged global identities and selected one freshest valid
observation. Swift never repeats that policy. Never add or average percentages across devices.

Overview is quota and nothing else. Provider groups carry quota only: models, messages, and period
totals stay on the Usage detail page in Settings and never create or extend an Overview provider
group. What today cost is the shell's bottom bar, not an Overview row.

Each quota observation shows:

- provider brand and name;
- optional masked account label and normalized plan badge;
- remaining value as the strongest number, with no "left" or "remaining" suffix;
- budget windows that also have an absolute remaining amount as `71% · $3.75`;
- percent-only windows as `71%`;
- balance-only windows as `$12.34` (or the unit amount) under a **Balance** title;
- one meter per quota window when a percent is meaningful;
- reset time as quiet metadata. Reset copy uses weekday and time within six days, otherwise month
  and day; it does not imply the window period.

An Overview row spends no line on which source answered or how old its reading is. A reading that
no longer describes live quota says so in tone — muted value, meter at reduced opacity — and the
sentence that tone replaces is what VoiceOver announces for the row: the account, the source
display name, and the shared freshness line (`Account: pe***@example.com. Studio Mac. Updated 3m
ago`). Tone alone never carries the state. The provider detail page in Settings keeps the per-source
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

Settings section order is fixed:

1. **Account**
2. **Quota**
3. **Menu Bar**
4. **General**

The Account group on Settings is one row deep in every state:

- Signed out or not checked: one standard-height **Sign In** row.
- Login running: one standard-height browser completion row with **Cancel**. Cancellation sends the
  typed service operation and closes the browser flow.
- Signed in: one row titled with the account label, which opens the **Account** page.
- Logout pending: one standard-height status row with **Retry Logout**.
- Removed or expired device session: use the same **Sign In** action and never show raw reason codes
  or ids. Authentication-provider choice belongs to the login flow, not this row's label.

The Account group is the only place for account authentication actions. Buttons invoke typed private
service operations; there are no embedded web views.

Quota contains the **Usage** and **Agents** destinations. The Usage root summary uses account-wide
totals while signed in with Usage sync enabled, and local totals otherwise. Menu Bar contains
**Style** and **Provider**: two rows that state the choice in force on the right and open a page to
change it, never a menu that drops over the panel. General contains the native mini **Launch at
Login** switch, the **Refresh Interval** destination (1, 2, 5, 10, or 15 minutes, default 5),
then the **Support** destination. Choosing an interval takes effect and returns, like Menu Bar
Style. It is how often this Mac collects provider quota; Account summary still polls every
minute, and a window reset can collect quota once before the next interval.

**Menu Bar Style** and **Menu Bar Provider** are one list each, with no section header to repeat the
page title. Every option is one ordinary settings row; the one in force carries an accent checkmark;
choosing takes effect and returns, because there is nothing else on the page to confirm. The Provider
page lists **Automatic** first, without a mark because it is not a provider, then the providers
Overview is showing, in Overview's order, each with its catalog brand mark.

Support is where help lives, and it asks the service nothing on its own: opening it starts no
check and costs no refresh. **Help** contains the **Diagnostics** destination, **Feedback**, and
**Reset Local Data**. Reset Local Data always confirms first and says plainly that collected quota
and Usage history are deleted and rebuilt and that the person stays signed in. That confirmation is
`QuotaConfirmationPopup` at the panel root, like Sign Out and Disconnect. **About** stays last with
Website, version, and **Updates**, which opens Sparkle's standard updater; Sparkle also
checks on a daily schedule after launch.

Diagnostics is the diagnostic page, one level inside Support. It is backed by the private
`diagnose` operation and opens with the report's status line: a semantic icon, **All systems
working** / **Some checks need attention** / **Action needed**, and a fixed locale-shortened
evaluation time (`Checked 3:40 PM`), not relative age.

**Data** contains Quota Overview, This Mac Usage, Account Usage, and Account only, in that order.
**Sources** follows it and appears only when the service sent any: one row per provider, Usage
agent, or service-owned path, titled by provider or agent display name and the rung that answered.
Every subtitle on both lists is the sentence the service wrote — never a raw state word, a wire
code, or a metric key — and each row carries a semantic icon (accent check, grey inactive dash,
orange warning, red blocked mark).

**Report** follows with **Copy Report**, which writes the human-readable text report, including the
recent work the page does not list, and whose row title becomes **Report Copied** for about two
seconds. It lives here rather than on Support because here is where the report exists.

Recheck lives only in the page header; opening Diagnostics resets and requests a real refresh so
re-entry never silently shows a previous report. That initial check uses a centered page Loading
state. Its failure uses a centered Error state with **Retry** as the only recovery action and no
header actions. A later Recheck preserves the last completed report; failure adds a fixed inline
warning above the report's scrolling content instead of replacing the page and enables Recheck
again. The Usage source control is not repeated in Settings. **Show in Overview** remains
presentation-only and has no diagnostic or local-collection meaning.

Page navigation animates an immutable presentation snapshot. Async work and model updates continue
during the transition, while the shared page host coalesces presentation changes and publishes only
the latest state after the navigation animation is removed. Any page that can replace loading,
empty, error, or content at its root uses this host; individual pages must not delay requests or
guess the navigation duration. Header actions stay hidden during the transition and then reflect the
published page state. Reduce Motion skips the transition and publishes updates immediately.

### Account

The Account page is reachable only while signed in, and it holds everything that belongs to the
account, top to bottom: the account label, the native mini **Sync Usage** switch, **Devices**,
**Open quota.gotry.io**, and **Sign Out**. Sync Usage keeps its behaviour and its copy — it is on
this page because what it uploads is account data, not a general preference.

**Sign Out** is the one destructive row, below the group, and it opens an app-owned confirmation
popup with **Cancel** and destructive **Sign Out** actions stating that the remote Device and synced
data remain. Do not use a system alert for this flow. Signing out closes this page, along with
anything opened from it, because there is no longer an account to manage.

### Devices

Devices is read-only in QuotaBar. Each row is the device display name, its platform, and the one
activity line from the shared vocabulary — a trailing **Active** / **Idle** / **Not reporting**
verdict beside `last reading 5m ago`, or `no readings yet`. Never a claim that a sleeping or closed
app is broken. Signed-out remains explicit. Never display raw Device IDs or request a provider login for
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
- Models: grouped by the vendor whose model it is — the service resolves that from the model's name
  — independent of the collecting client and of who billed the request. Every model remains a
  static single row ending in `tokens · cost` when priced, or only `tokens` when unpriced.

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

### Agents

Agents has **Shown in Overview** and **Hidden from Overview** groups. Shown providers support drag
reordering and VoiceOver Move Up/Move Down actions. A quiet desktop symbol means an account device
has a presentable observation for that provider.

Provider detail contains:

- **Overview**: provider-wide visibility switch;
- **Reporting From**: This Mac or account device display names, the source kind, and the shared
  freshness line for that reading;
- **This Mac Sign-in**: the catalog-provided copyable official-provider command, shown with Browser
  Session unless that session is catalog `exclusive` (Cursor); or
- **This Mac Configuration**: native secure API-key entry, optional base URL when catalog-enabled,
  masked saved state, Save, and Remove; and
- **Browser Session** when catalog-enabled (Cursor, Codex, Claude, Grok, Kimi): disconnected
  **Sign In**, bounded **Waiting / Cancel**, non-cancellable **Connecting** after commit begins, or
  a connected masked account with only **Disconnect**. Sign In, Cancel, and Disconnect are the same compact secondary
  control; do not use an accent capsule or explanatory body copy on this surface. Confirmed
  disconnect is likewise non-cancellable. There is no switch-account action; a different account is
  disconnect, then sign in. A read macOS refused is its own row, carried by
  `exclamationmark.triangle` rather than the generic `exclamationmark.circle`, and it replaces the
  ordinary error line rather than stacking with it.

Browser-session login uses app-owned selection/confirmation popups at the panel root, never system
alerts or sheets. Login is pinned to one supported browser; an unsupported default HTTPS handler
requires a browser selection before opening the URL. One unambiguous new account may commit
automatically; multiple accounts require selection. Lists scroll within the panel; the popup owns
focus, Escape, keyboard, and VoiceOver while the underlying page is disabled and accessibility-hidden.

**Consent copy.** Reading another program's cookie jar is the one thing this app does that a person
has to agree to, so a confirmation popup states what is about to happen before it happens, once the
browser is known and before any store is opened. Cancel and Escape read nothing. The message says,
in this order and in plain sentences: which browser will be read, by name; which hosts and which
cookie names, both quoted from the catalog so the sheet cannot promise a narrower read than the one
that follows; the permission macOS will ask for, naming only the gatekeeper that browser actually
has (Full Disk Access for Safari, the "Chrome Safe Storage" Keychain item for a Chrome-family
browser, neither for Firefox); that the accepted session is stored in QuotaBar's local service
database on this Mac until disconnected; and that nothing about it is uploaded. Confirm reads
**Read Cookies**, never "OK" or "Allow".

**Refusal copy.** A store macOS would not open is a different state from finding no session, and it
never reads as one. Each refusal names the browser and the single next action — grant Full Disk
Access, allow the Keychain item, or quit the browser and retry — and never a store path, a profile
name, or the underlying error's text. It ends the attempt rather than continuing to poll.

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
| `CacheRebuildNotice` | Inline notice while local Usage history is being rebuilt |
| `QuotaSectionStateView` | Left-aligned Loading, Empty, or Error scoped to one section |

Prefer these components over page-local replicas. In-section actions never mix an accent capsule
with a system or bordered control. **Save** and empty-state **Retry** use compact primary. Browser
Session **Sign In**, **Cancel**, **Remove**, and **Disconnect** use secondary; destructive labels
use the destructive variant. Diagnostics' Recheck is a header icon action only; Copy Report and
Reset Local Data are Settings list rows. Full-width Settings rows such as **Sign Out** stay list rows. Do not use
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
Required routes are Overview, Settings, Account, Agents, provider
setup variants (CLI, API key, and browser session), Devices, Usage, Menu Bar Style, Menu Bar
Provider, Support, and Diagnostics. Inspect
light and dark appearances, standard and accessibility text sizes, keyboard traversal, VoiceOver
labels, and Reduce Motion transitions.

Synthetic fixtures may contain display labels and opaque ids needed for typed models, but must never
contain access tokens, refresh tokens, provider secrets, or raw production data.
