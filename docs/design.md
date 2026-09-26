# Quota design

This is the single owner of Quota's shared visual language: the five principles, colour and type
roles, component and chart grammar, product vocabulary, and voice. Hex values, remaining-quota
thresholds, spacing, and radii live only in
[`packages/design-tokens/tokens.json`](../packages/design-tokens/tokens.json). Each app's
`DESIGN.md` lists platform deltas and screen specifications.

- QuotaBar: [`apps/menubar/DESIGN.md`](../apps/menubar/DESIGN.md)
- Quota iOS: [`apps/ios/DESIGN.md`](../apps/ios/DESIGN.md)
- Quota Web: [`apps/web/DESIGN.md`](../apps/web/DESIGN.md)

Provider ids and marks stay in [`packages/provider/catalog.json`](../packages/provider/catalog.json).
Tone thresholds may be generated constants; the remaining-quota classifier stays domain logic with
conformance tests. Pace algorithms and English sentence catalogs do not belong in the token file.

## Five principles

1. **A glance answers quota; an analysis page tells the reader's usage.** Glance surfaces — the
   QuotaBar panel, the iPhone Quota tab, widgets — answer “Can I keep working?” first: remaining,
   then when it resets, then a risk sentence when one exists. Analysis surfaces — the website's
   `/my`, the iPhone Usage tab, the QuotaBar Usage page — open with one sentence about the
   reader's own model usage, then the model chart and ledger, with quota kept in view (on the web,
   the quota band). See [ADR 0064](decisions/0064-analysis-surfaces-lead-with-model-usage.md).
2. **A number keeps its meaning everywhere.** Remaining is remaining. A period uses one timezone.
   Money names its cost basis. A stale reading keeps the last observation and says why it is not
   current.
3. **One emphasis per group.** A quota value or the selected metric dominates. Supporting counters
   and plan badges do not compete.
4. **Native structure, shared semantics.** System navigation, menus, forms, and accessibility.
   Shared colour roles, chart grammar, value hierarchy, and copy.
5. **Trust is visible.** Last-good content stays. Unknown, zero, stale, and failed are distinct.
   The action that can fix a problem is stated in words, not colour alone.

## Colour

Roles by name. Values live in
[`packages/design-tokens/tokens.json`](../packages/design-tokens/tokens.json); do not copy them
here.

| Role | Meaning |
| --- | --- |
| `text.primary` | The reading itself: remaining figures, titles, primary actions. |
| `text.secondary` | Supporting labels and navigation. Not the only carrier of a recovery instruction. |
| `text.meta` | Age, reset, tertiary metadata. Small but readable; never opacity-reduced primary. |
| `surface.canvas` | Page and grouped background. |
| `surface.content` | Cards and grouped content. |
| `border.subtle` | Decorative divider, not the sole control boundary. |
| `brand.accent` | The Quota mark, focus, switches, primary Quota actions, cached input, and the healthy remaining fill. Never a model or vendor colour. |
| `quota.healthy` | Remaining that is enough to keep working. The percent sits next to the bar. |
| `quota.warning` | Remaining that is getting tight. The percent sits next to the bar. |
| `quota.critical` | Remaining that is likely to stop the reader. The percent sits next to the bar. |
| `meter.track` | Neutral unfilled meter. Not an available or unknown state by itself. |
| `activity.0`…`activity.4` | Activity and rhythm volume steps. The legend states the scale. |
| `chart.cache` | Cache read in a token stack or mix. The brand colour: cache is what Quota helps the reader keep. |
| `chart.cache_write` | Cache write, where the data separates it. Brand light. |
| `chart.input` | Fresh (uncached) input. Neutral. |
| `chart.output` | Output, reasoning included. Ink. |
| `model.<provider>.1`…`4` | A model's fill in a chart, ledger swatch, or flow. The family is the model's inference provider; the shade is its rank inside that provider. |
| `model.other` | Every model ranked fifth or lower inside its provider, and the folded rest of a top-N series. |

Roles the token file does not store as swatches, but every surface still uses:

| Role | Meaning |
| --- | --- |
| Pace risk | Warning colour plus an explicit sentence. Independent of the remaining band: a healthy remaining can still run out before reset. |
| Destructive / error | Failure and destructive actions. Never red for signed-out or disconnected. |
| On accent | White on emerald in light; dark ink on mint in dark. Identity avatars that need white-on-green use brand emerald in both appearances. |
| Focus | Platform focus. Web uses a solid accent outline and offset. Never hover-only. |

Colour never carries status alone. Every state also has a text label.

**Model colours.** A model's colour comes from its inference provider's family (`anthropic`,
`openai`, `google`, `xai`, `moonshot`, `deepseek`, `cursor`, `unknown`) and its rank by tokens
inside that provider over the Account's `all` period: ranks 1–4 take shades 1–4, anything lower is
`model.other`. The rank is over all history, not the period on screen, so switching period, page,
or device never recolours a model. A tie inside a provider goes to the model name in ascending
order, so every device agrees. Each platform writes one pure function for that assignment
(`ModelColorAssignment` in `packages/apple-shared` on Apple) and every chart on the surface uses
it. Never assign colour by rank across providers, and never make a model mint. Amber and red
appear only for risk. Model fills are chart fills that always sit beside a name, a ledger row, or a
label, so they are not held to 3:1 against the canvas (WCAG 1.4.11 applies where a fill is the only
carrier, which no Quota chart allows); inside a family, shade 1 stands out most from the canvas and
each later rank less.

### Apple overrides

Apple does not take the CSS RGB text roles wholesale. The overrides live under
`overrides.apple` in the token file because system text roles and contrast on grouped backgrounds
are platform facts, not a second palette.

- `text.primary` and `text.meta` map to system label colours so Dynamic Type, Increase Contrast,
  and vibrant rendering keep working.
- Light `text.secondary` is darkened so support text stays at least 4.5:1 on grouped backgrounds;
  dark stays `secondaryLabel`.
- Card radius is 20 on Apple and 16 on the web.
- Meter track is `tertiarySystemFill`.
- Activity empty cells use `separator`. Non-empty steps keep the shared fill ramp and take a
  contrast-safe outline, so WCAG 1.4.11 does not force the ramp to collapse into one fill.
- Chart output on Apple is `label` at reduced opacity so it follows Increase Contrast; cache, cache
  write, fresh input, and model fills are the shared values.

### Spacing, radius, motion

Spacing steps are 4, 8, 12, 16, 24, 32, 48. Card inset 16; content gaps 12; sections 24; desktop
page gutter 24. Radii: control 8, group 12, content card 16 (Apple 20), capsule full. System
controls keep their own shape.

Native material and glass belong on panel, navigation, and transients. Data cards are opaque
(`surface.content`). Do not add decorative drop shadows or a second card language.

State changes are short; navigation is a little longer. Honor reduced motion. Clocks and
refreshes never animate the whole layout.

## Tone bands

Remaining at or above 40 is **healthy**: enough to keep working. Remaining at or above 15 is
**warning**: getting tight. Below 15 is **critical**: likely to stop the reader. The percent is
always printed; the band is not a substitute for the number.

Pace risk is a separate question: whether the current rate lasts to the reset. A window at 70
remaining can still run out early, and then it uses the warning colour because of pace, not
because of the remaining band.

Spend meters (monthly budget) are not remaining. They use the same three colours with their own
thresholds, documented on the Usage screens that draw them.

## Type

Roles are shared. Absolute sizes are not. These are defaults, never fixed-height text boxes.

| Role | iOS | Mac window / compact panel | Web account UI |
| --- | --- | --- | --- |
| Page title | system `largeTitle` | title / 13pt semibold panel title | 28–32px, 1.15 line height |
| Section title | `title3` semibold | 17pt / 12pt semibold | 20px, 1.3 |
| Card identity | `headline` | 15pt / 13pt semibold | 16px semibold |
| Primary numeric | rounded `title`, tabular digits | 28pt / 16pt tabular | 28px tabular; rounded fallback allowed |
| Body / control | `body` | 13pt / 12–13pt | 16px, 1.5 |
| Supporting label | `subheadline` | 12pt / 11–12pt | 14px, 1.4 |
| Metadata | `footnote` | 11–12pt / 11pt | 13px, 1.4 |

Dynamic Type reflows rows and turns stat grids into one column; a period chooser becomes a menu
at large sizes. Never shrink essential remaining figures to half size as the primary escape —
wrap, stack, or scroll instead. Web uses rem-based sizing. Mac compactness is intentional, but
10pt tertiary text must not carry a necessary recovery instruction. Monospaced *digits* are
useful; monospace prose is not a brand.

Each app maps these roles onto named styles (`QuotaDesign.Typography` on Apple, CSS custom
properties on the web). Those names are platform deltas.

## Components

Semantics, not layouts. Do not demand one shared SwiftUI card for Mac and iOS. Share small
drawing primitives and resolved presentation data when they are identical; share behavior tests,
not a universal layout engine. Widgets consume the same roles and values, with widget-owned
backgrounds and system accent or monochrome. Colour is optional information there: the
percentage and freshness must survive removal of all colour. Widget extensions do not link the
provider-mark catalog.

| Component | Contract |
| --- | --- |
| Card | One subject and one dominant value; optional heading or action. No nested card wall. Analysis pages group data in hairline-separated sections, not bordered cards. |
| Sentence header | Eyebrow (page · period), then one sentence written from the reader's numbers, numbers in ink and the rest in body colour, then controls, then one meta line of supporting facts (cost, cache share, active days, change against the previous period). Loading and empty states are sentences too. It never ranks the reader against anyone. |
| Stat tile | Label, number, basis or coverage. Not the default headline of an analysis page — the sentence header is. Allowed where space is dense (a detail page, the public page, a panel). At most two primary stats per group. |
| Quota window | Window title, remaining, meter, reset; risk only when the pace rule answers. |
| Meter | Linear remaining 0…100, exact zero, no minimum quantitative fill. A capped amount (`$12.50 of $40.00`) replaces a redundant percent bar. Hidden from VoiceOver when the remaining figure is already spoken. The default for every window. |
| Even-pace tick | A thin tick on a meter where remaining would stand now at an even burn rate. A fill ending short of the tick is burning faster than an even pace. Only where the pace rule answers; hidden from assistive tech, because the pace line says it in words. |
| Quota band | On analysis pages, one row under the header: per subscription an 18-point ring of its tightest window's remaining in the band colour, provider name, remaining percent, window title; a stale reading shows its status word, a balance its amount. Each item links to the subscription; the row ends with **Quota →** and scrolls sideways when narrow. |
| Tightest-window gauge | The Quota mark's ring at size, remaining as the arc in the band colour, the percent inside. Only for the single tightest window at the head of a quota page; every other window is a linear meter. |
| Next resets | The next seven days in local time, one lane per current subscription, a ring per reset instant in the band colour of the window it refills (the lowest when several coincide, which is resetting in the same minute), labelled with window titles. Its text alternative is each window's **Resets** line. |
| Pace line | Optional explanatory projection, never a second unlabeled headline. Solid observations, dashed estimate, reset endpoint. The dashed end agrees with the pace sentence. |
| List row | Leading identity, main text, trailing value or action. The full target is only a control when it navigates or acts. |
| Capsule | Short plan or scope descriptor; neutral unless it truly signals state. Never a fake button. |
| Daily chart | The same local dates as the summary. Zero is a baseline tick, not a short bar. Two or three value ticks, date ticks, selected-day detail. Tokens stack cache read, fresh input, and output in the chart roles. |
| Model river | Stacked area by model per local day, largest model at the bottom, the top models plus `other`. A metric switch in the chart head (Tokens, API-equivalent cost, Messages) and Amount / Share. The current day is hatched as in progress. An empty day stays in the axis with a baseline tick: in Amount the stack meets the baseline there; in Share the areas break over that day rather than drawing a 0 % dip. Labels sit at a stream's end when there is room; otherwise the ledger under it is the legend. |
| Model ledger | The legend is the table: swatch, model (names merged across agents and aliases), tokens, share, change against the previous period (**↑ 4 pts**, **New**, or **—**), from cache, and cost, each row tinted by a bar of its value in the model colour. Six rows then **N more models** with their total; the models page lists all. |
| Token mix | One bar of cache read, cache write, fresh input, and output that adds up to the period's tokens, with percentages, reasoning named inside output, and what cache saved in dollars against list price ([ADR 0036](decisions/0036-usage-derived-metrics.md)). |
| Agents → models | Agents on the left in ink, models on the right in model colours, ribbons as wide as the tokens one sent to the other, top eight models. Each ribbon names its pair and tokens for assistive tech; where too narrow, the same pairs are a grouped list. |
| Weekly recap poster | One week, one number and one sentence per poster: volume, model of the week, cache efficiency, rhythm, headroom now. **Copy as image** on each; private until copied. No streaks, no ranking, no volume record. |
| History chart | The running window, 0–100. Reset cycles do not imply continuous consumption; gaps stay gaps. Several windows of one provider use dash or label as well as colour. |
| Activity / rhythm | Secondary exploration. Explicit timezone and scale legend. Not automatic dashboard wallpaper. |
| Empty / error | No-data explanation plus one primary action. Local versus Account only where that distinction is actionable. Last-good remains on a partial failure. |

Marks: a 20–24pt optical provider mark with its name; a 36–40pt detail mark only when it
replaces a heading rather than duplicating it; QuotaBar's menu-bar template is optically fitted
to the bar. Do not repeat logos on every model row. Unknown providers use a text fallback.
Emerald is for Quota actions and state, not to recolor every vendor in Settings.

## Shared product vocabulary

These rules apply to every Quota client. Exact strings and thresholds are the conformance
fixtures named below; change the fixture, not a surface.

- **Freshness is relative age, everywhere.** A current reading reads **Updated 3m ago**. A
  reading that no longer describes current quota names why and when it was last taken: **Not
  current — last reading 2d ago**, or **Sign-in needed**, **Unavailable**, **Unsupported**,
  **Can’t refresh** in place of *Not current* when the source itself reported that. Anything
  under a minute is **just now**, because a number that changes while it is being read is noise.
  Nothing shows a clock time or a calendar date for a past reading, and nothing shows a bare age
  with no words around it. The exact phrases and thresholds are
  `packages/protocol/fixtures/freshness-copy-conformance.json`.
  `packages/apple-shared` (`FreshnessCopy`) and `apps/web/src/lib/format.ts` both answer that
  file, so a phrase one of them changes cannot drift from the other.
- **A future reset is a countdown or a local date, never an age.** All of it is relative to the
  reader’s time zone, and the English is fixed: it does not follow the device locale. Relative
  (the default): under an hour **Resets in 42m** (minutes round up; anything under a minute is
  still **Resets in 1m**); from one hour to a day **Resets in 3h 12m**, or **Resets in 3h** when
  the minutes are zero; from a day to a week **Resets Tue 14:00** (weekday abbreviation and
  24-hour `HH:mm`); a week or more **Resets Sep 12** (month abbreviation and day). Absolute
  always uses that local date, even under a day. A reset that has already passed prints no
  Resets line; the reading is **Not current**, or the status word the source reported.
  `packages/protocol/fixtures/reset-copy-conformance.json` is the shared statement. QuotaBar
  Settings → Menu Bar → **Reset time** switches relative and absolute; iOS and the website stay
  on relative.
- **Remaining has no “left” or “remaining” suffix.** usd and credits remaining of a cap print
  `$12.50 of $40.00` (or `80.00 of 100.00 credits`) and drop the percent bar, when
  remaining/limit describes the same quantity as `used_percent`. Included dollars that are a
  different quantity keep `36.9% · $14.55` and the meter. Percent-only windows use `71%`.
  Balance-only windows use **Balance** plus the unit amount. Empty windows: **No quota windows
  yet.** `packages/protocol/fixtures/remaining-copy-conformance.json` is the shared statement.
- **A pace line says whether the current rate lasts to the reset.** Glance surfaces print the
  outcome only — **Expected to last until reset**, or **May run out about 2h before reset**. The
  duration in *May run out* is the shared compact format (`2h`, `27m`, `1d`) and always reads
  *about*, because it is a projection. Detail surfaces add an explanation under that headline:
  **Using quota faster than an even pace (+70 points)**, **Using quota slower than an even pace
  (−30 points)**, or **Using quota at an even pace**. The signed figure is percentage points off
  an even burn rate, not percent of the window. A window the rule cannot answer for — no
  cadence, a balance with no limit, or too little of the window elapsed or used — shows no line
  and takes no space. *May run out* is the warning colour; everything else is secondary text.
  The rule and these phrases are `packages/protocol/fixtures/quota-pace-conformance.json`,
  answered by `packages/quota-model`, `packages/service`, `packages/apple-shared` (`QuotaPace`,
  `QuotaPaceCopy`), and `apps/web/src/lib/format.ts`; see
  [ADR 0035](decisions/0035-quota-pace-is-derived-from-the-reading.md).
- **A pace line has a picture: the window's own samples, drawn under its meter.** Solid over the
  readings this device took inside the running window, dashed from the last of them to where
  ADR 0035's projection lands at the reset. The vertical axis is the whole window, 0 to 100
  percent used, so two windows of different cadences are read the same way; the horizontal axis
  is the window's start to its reset. It takes the meter's own colour. A window with no samples
  yet — a new install, a rebuilt cache, a reading that came from another device — shows no line
  and takes no space, unless the Account's history switch is on and the chart is drawing the
  Account series. Samples stay on the device by default; they upload as downsampled buckets only
  while that switch is on
  ([ADR 0042](decisions/0042-quota-history-is-local-samples.md),
  [ADR 0062](decisions/0062-quota-history-may-follow-the-account.md)).
- **A provider group ends with the day it has had.** One secondary line, **Today: 3 windows ·
  82% / 40% / 12%**, oldest first, that opens into a row per window naming the local clock times
  it ran between and its peak. Singular is **1 window**. The day is the primary-cadence
  window's, so both Apple surfaces answer for one window rather than for whichever happened to
  have samples. A provider whose day holds no window shows nothing. The fold is
  `packages/protocol/fixtures/quota-history-conformance.json`, answered by `packages/service`
  and `packages/apple-shared` (`QuotaHistory`, `QuotaHistoryCopy`).
- **A window with no reported refill instant reads “No reset time reported.”** One phrase. A
  percent window that is still full omits the line: there is no refill to wait for.
- **Provider names come from the catalog.** `display_name` in
  `packages/provider/catalog.json` is the only place a provider is named for a person. No
  surface keeps a second table and none derives a name from an identifier.
- **Billing agent names come from `BillingAgent.displayName`.** QuotaWire owns that table beside
  `ProviderID.displayName`. No surface keeps a second table.
- **Quota window titles are Title Case.** Cadence names are **5 Hours**, **Weekly**, and
  **Monthly**. Acronyms keep their standard forms: **GPT**, **API**, **OAuth**, **USD**. Extra
  Codex limit names follow that rule (`gpt-reserve` reads **GPT Reserve**). Collectors write
  these titles; surfaces print them as received.
- **A device row states one verdict and the one age it came from**: **Active** under thirty
  minutes, **Idle** up to a day, **Not reporting** beyond that, and `last reading 5m ago` from
  the instant that decided it. Never a list of report, refresh, and sync timestamps.
- **Scope names are This Mac, This iPhone, Account, and All devices** when the reader needs to
  know whose numbers they are. They are not a prefix on every line. Counting how many readings
  came from this device and how many from the account is implementation detail; whether the
  numbers are still current is not.
- **API-equivalent cost is the label for estimated comparable API pricing.** Do not silently
  rename it spend or imply an invoice. Compact forms: complete `$X.XX` (or `$X` where the
  surface is that tight), partial `≥ $X.XX`, unavailable **— unpriced**. Cost always says how
  it was arrived at.
- **User-facing copy uses product words.** Nothing on screen names coverage, UTC hours,
  generations, revisions, fingerprints, sequences, protocol versions, or the private service's
  implementation.
- **Notification copy.** Title is **`<Provider display_name> · <Window title>`**. Body is
  **`12% left · resets in 42m`**, using the shared reset countdown in lowercase; if that
  countdown is nil, the body is only **`12% left`**. A window refill reads **`<Window title>
  quota reset`**. Product copy says Quota reminds when a refresh brings new data; it does not
  promise real-time. When a remaining-quota reading should fire a local threshold or reset
  notification is `packages/protocol/fixtures/alert-transition-conformance.json`; QuotaBar and
  Quota iOS both answer that file through `QuotaAlerts`. A pace warning reuses the pace line as
  its body, and fires at most once per window per reset cycle.
- **A Usage page shows one period, and there are seven of them.** Three are anchored to the
  reader's own calendar and step a unit at a time — **Today**, **This week**, **This month** —
  and three are fixed windows — **Last 7 days**, **Last 30 days**, **All**. The seventh is
  **Custom range**, two inclusive dates someone picked. Relay's `all` is the last 730 UTC days,
  not every day ever stored. A control too narrow for the full name abbreviates it **Day**,
  **Week**, **Month**, **7D**, **30D**, **All**, **Custom**; the accessibility name is always the
  full one. The website adds **Last 90 days** (**90D**), which its period read answers and the
  Apple clients' folded periods do not. `UsagePeriodSegment` in `packages/apple-shared` and
  `USAGE_PERIOD_SEGMENTS` in `apps/web/src/lib/usage-period.ts` are where those pairs are written.
- **A period says the range it covers, not the name of its button.** One day is that date
  (**Sep 6, 2026**); a range inside one year drops the repeated year from its first half
  (**Aug 31 – Sep 6, 2026**); `all` has no first day, so it reads **Everything kept**. The step
  controls are **Previous period** and **Next period**, and there is nothing ahead of the
  current day, week, or month, so **Next period** is disabled there. Exporting the period writes
  those same local dates, the same zone, and the same API-equivalent cost
  ([ADR 0056](decisions/0056-a-period-export-is-the-period-on-screen.md)).
- **Four periods are folded for the reader, and the rest are folded by the client.** Today, Last
  7 days, Last 30 days, and All arrive folded — from the service on This Mac, from the Account
  read on Account. Every other period is added up by the client from days it already holds, and
  days carry no agent tree, so a folded period shows totals and cost with no model breakdown and
  says so in one line rather than looking empty. On Account, a period the summary does not carry
  is answered on This Mac only.
- **The monthly budget follows the Account.** It is one amount in US dollars plus whether it may
  notify, in the Account settings document with the alert policy
  ([ADR 0061](decisions/0061-alert-policy-and-the-budget-follow-the-account.md)); `UserDefaults`
  on Apple and `localStorage` on the website keep the local copy, and which crossings a device
  already announced stays on that device. Signed in, every client measures it against the
  Account's calendar month; signed out, against what the device has, and the surface says which.
  It reads as a progress bar **`$5.39 / $50.00 · 11%`**, with **`≥ `** in front of a spend only
  partly priced. Crossing 80% and then 100% of the amount notifies once each per
  calendar month: the title is **`Monthly budget`** and the body is **`80% of $50.00 spent`**,
  or **`$50.00 budget spent`** once the whole amount is gone. A new month starts a new cycle.
  When those crossings fire is `packages/protocol/fixtures/alert-transition-conformance.json`
  (`budget_cases`), which both Apple apps answer through `QuotaAlerts`.
- **An empty day is a tick, not a bar.** A day the period covers that reported no usage is drawn
  as a 2-point baseline tick in the tertiary fill, so the day is present and has no height. It
  is never a short bar of usage. In Cost mode, a day the catalog could not price is a distinct
  **unpriced** mark at that same tick height — hatched or outlined — and is named unpriced,
  never **$0**. Spoken chart summaries follow the Tokens / Cost mode the bars are measuring.

## Voice

Short, factual, helpful. **Updated 3m ago.** **Couldn't refresh. Showing saved quota.**
**Reconnect Claude Code.** **No usage in this period.**

Keep the Quota mark and the existing provider marks. No rebrand. Preserve third-party
attribution. Product names are Quota, QuotaBar, and QuotaRelay. Use ordinary lowercase
account, device, and provider nouns in prose; reserve branded capitalization for product names
and actual screen labels.

**Sign in to Quota** is the invitation onto an Account. **Connect Codex** (or **Connect a
provider**, **Sign in to Claude Code**) is the invitation to read that provider on this device.
They are not interchangeable: one names Quota, the other names the provider.

Avoid implementation nouns such as snapshots, folds, and installations in routine flows.
