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
- **A future reset is a countdown or a local date, never an age.** All of it is relative to the
  reader’s time zone, and the English is fixed: it does not follow the device locale. Under an
  hour: **Resets in 42m** (minutes round up; anything under a minute is still **Resets in 1m**).
  From one hour to a day: **Resets in 3h 12m**, or **Resets in 3h** when the minutes are zero. From
  a day to a week: **Resets Tue 14:00** (weekday abbreviation and 24-hour `HH:mm`). A week or more:
  **Resets Sep 12** (month abbreviation and day). A reset that has already passed prints no Resets
  line; the reading is **Not current**, or the status word the source reported. The `reset` array in
  the same fixture is the shared statement of these thresholds.
- **A window with no reported refill instant reads “No reset time reported.”** One phrase. A percent
  window that is still full omits the line: there is no refill to wait for.
- **Provider names come from the catalog.** `display_name` in `packages/provider/catalog.json` is
  the only place a provider is named for a person. No surface keeps a second table and none derives
  a name from an identifier.
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

Settings → Menu Bar → **Style** chooses **Icon**, **Percent**, or **Icon and percent** (the default).
→ **Provider** chooses **Automatic** — the tightest current subscription — or any set of providers
Overview is showing. Two or three named providers can be **Combined** into one item or **Separate**
as one item each; Combined is the default arrangement for that size, and a fourth named provider
makes the bar Separate. More than one named provider always draws as Icon and percent, because
Icon-only and Percent-only cannot say whose number it is. The stored Style is left alone and
applies again when the bar is back to one reading. Style choosing takes effect and returns;
Provider is a set of toggles and stays until Back. Both the named set and the arrangement persist
in UserDefaults. A chosen provider with no current reading shows the mark alone and never borrows
another provider's number, and **Percent** likewise falls back to the mark alone when there is no
percent to show, because an item with no content cannot be clicked. VoiceOver announces
**QuotaBar**, the provider each number belongs to, and the remaining percent — or, for a stacked
pair, the full window titles: **QuotaBar, Claude Code, 5 Hours 68% remaining, Weekly 27% remaining**.
Clicking a Separate item opens the shared panel on that provider; Combined and Automatic open the
same panel without changing page.

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
            └── Source
```

### Overview

Render the service-provided Overview in saved catalog order. Each provider row may contain multiple
account observations; Rust has already merged global identities and selected one freshest valid
observation. Swift never repeats that policy. Never add or average percentages across devices.

Overview is quota and nothing else. Provider groups carry quota only: models, messages, and period
totals stay on the Usage detail page in Settings and never create or extend an Overview provider
group. What today cost is the shell's bottom bar, not an Overview row. The provider heading is
the only Overview destination into that agent's Settings page (`Settings → Agents → Provider`).
It is a destination at `minimumInteractiveDimension` (28pt), not a Settings list row. Brand,
name, status, and chevron stay on the 16pt content guide with the quota windows. Hover/press
extends 8pt into that gutter on each side, so the bar is wider than the numbers and still
has margin from the panel edge. Overview is not a Settings group and does not use the group's
4pt nested inset. Quota windows, account labels, and status detail under it are static
reading content and do not take that surface. The heading remains keyboard and VoiceOver
reachable. Back follows the stack.

Each quota observation shows:

- provider brand and name;
- optional masked account label and normalized plan badge;
- remaining value as the strongest number, with no "left" or "remaining" suffix;
- budget windows that also have an absolute remaining amount as `71% · $3.75`;
- percent-only windows as `71%`;
- balance-only windows as `$12.34` (or the unit amount) under a **Balance** title;
- one meter per quota window when a percent is meaningful;
- reset time as quiet metadata, in the shared reset copy; it does not imply the window period.

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
- Login running: one standard-height browser completion row with **Copy Link** and **Cancel**.
  Cancellation sends the typed service operation and closes the browser flow. Copy Link puts the
  authorize URL on the pasteboard. If QuotaBar could not open the browser, the row stays in this
  state and the error reads **QuotaBar could not open your browser. Copy the sign-in link and open
  it yourself.**
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

**Menu Bar Style** is one list, with no section header to repeat the page title. Every option is one
ordinary settings row; the one in force carries an accent checkmark; choosing takes effect and
returns, because there is nothing else on the page to confirm. **Menu Bar Provider** lists
**Automatic** first, without a mark because it is not a provider, then the providers Overview is
showing, in Overview's order, each with its catalog brand mark. Automatic is exclusive with the
named set; named rows toggle and the page stays. When two or more are named, **Combined** and
**Separate** follow in a second group; Combined is unavailable past three.

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
reordering and VoiceOver Move Up/Move Down actions. Every row carries one status line under the
name — `SignInRungPresentation.statusLine`: **Signed in** (· *n* **accounts** when more than
one), **Configured**, **Reported by another device**, **Key rejected**, **Unavailable**, **Not
configured**, or **Not signed in** — so the list says which agent needs attention before it is
opened. The Settings home **Agents** row trails **3 shown** and, when any shown agent has no
working credential and no device reporting it, **· 1 needs sign-in**.

Provider detail is read top to bottom as three questions — is it shown, what is it reporting,
how does this Mac sign in — and contains exactly these sections, in this order:

- **Overview**: one **Show in Overview** switch, no subtitle. Visibility is provider-wide and
  presentation-only.
- **Accounts**: one group for every subscription. Each account is a bold row inside the group —
  the masked account label, or **Account 1**, **Account 2** when there is no label, so two
  accounts cannot share a blank name — with the compact source menu as that row's trailing
  control; its sources follow as indented destination rows, and a hairline separates one
  account from the next. The menu uses `fieldFill` on the 24pt compact surface
  (`headerControlSurfaceSize`) inside a 28pt pointer target, like header icon actions, and reads
  **Automatic** or **Show: <source>** when pinned, then a small `chevron.down` at affordance
  size. It opens an app-owned floating menu (the same material as Settings overflow), not a
  system Menu. Choice rows use `fieldMinHeight` (32pt); the first item is **Automatic** with
  the quiet line **Newest live reading** under it, the rest are the available sources with no
  subtitle and no leading icons; the accent checkmark after the title is the only selected mark.
  Escape or a click outside the trigger and list dismisses it. VoiceOver names the control
  **Show from** and states the mode (Automatic or Pinned), the source Overview is actually
  showing, and the freshness. Source rows are destinations only — device icon, name, the shared
  freshness line trailing, `chevron.right` — and never select. The source Overview is actually
  showing uses a filled device icon in accent; other devices stay outline in body. VoiceOver adds
  **Showing on Overview**. A pin whose source has gone is dropped and Automatic resumes. With no
  subscription yet the group holds one line: **No readings yet. Sign in below to start
  reporting.**
- **Source**: a read-only page titled with the source display name. Under **Quota** it states
  freshness, then that source's remaining-quota windows. It does not repeat the source name,
  source type, account label, or plan. If the snapshot is not yet available it keeps the
  freshness line and does not invent empty quota. If the source has gone: **This source is no
  longer reporting.** There is no **Use this source** action; selection stays on the provider
  page menu.
- **Sign-in**: one group listing every credential rung this Mac has for the provider, in the
  order collection tries them, each with the verdict the last collection reached. Rung rows
  are `SignInRungPresentation`'s: **Codex CLI** / **Claude Code CLI** / **Grok CLI** /
  **Kimi Code CLI** (`terminal`), **API Key** (`key`, a destination row to the API Key page),
  **Cursor App** (`macwindow`), and **Browser Sign-in** (`safari`, a switch). The trailing
  status word is **Signed in**, **Configured**, or **On** in accent; **Not signed in**, **Not
  configured**, or **Rejected** in warning; **Unavailable** in body with the collection message
  as the subtitle. A CLI rung that is not signed in shows the catalog-provided copyable command
  as an indented `QuotaCommandRow` under it; a signed-in one shows no command. Kimi's key and
  CLI-file rungs answer the report by different source ids (`kimi_code_usages_api`,
  `kimi_code_cli_credential`), so each row carries its own verdict. Cursor is catalog
  `exclusive`: it has no command row, and its first rung is the Cursor.app session.
- **API Key**: a page for the providers with a key rung — native secure entry, optional base URL
  when catalog-enabled, the masked saved state, Save, and Remove. The Agent page row shows the
  masked key and status only.
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

Turning Browser Sign-in on uses an app-owned confirmation popup at the panel root, never a system
alert or sheet. There is no browser picker, account picker, Sign In, or Disconnect. The popup
owns focus, Escape, keyboard, and VoiceOver while the underlying page is disabled and
accessibility-hidden.

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

On the Agent page the outstanding grants are one indented destination row under the switch — **Browser
Access** with a one-line summary such as **Safari and Chrome need permission** or **Relaunch
QuotaBar to finish granting Full Disk Access** — that opens the window; there are no per-browser
rows or action labels in the panel. The row disappears when every installed browser is readable.
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

## Shared components

| Component | Contract |
| --- | --- |
| `MenuBarShell` | Fixed header/body/footer geometry |
| `MenuBarHeader` | Back/title/root actions and keyboard-safe transient menu |
| `SettingsSection` | Quiet label, optional trailing control, plus adaptive group surface |
| `SettingsListRow` | Shared icon/title/subtitle/trailing alignment |
| `QuotaCommandRow` | Selectable official-provider sign-in command and Copy/Copied feedback |
| `QuotaConfirmationPopup` | Scrimmed app-owned confirmation with cancel and destructive actions |
| Browser Access window | Floating window independent of the menu extra; one row per installed browser with its icon, gatekeeper, and single action; Relaunch row after the Full Disk Access pane was opened; closes itself when nothing is outstanding |
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
setup variants (CLI, API key, and browser session), a source, Devices, Usage, Menu Bar
Style, Menu Bar Provider, Support, and Diagnostics. Inspect
light and dark appearances, standard and accessibility text sizes, keyboard traversal, VoiceOver
labels, and Reduce Motion transitions.

Synthetic fixtures may contain display labels and opaque ids needed for typed models, but must never
contain access tokens, refresh tokens, provider secrets, or raw production data.
