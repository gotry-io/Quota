# Quota Web Design

This file is the canonical visual and interaction contract for `apps/web`. Product boundaries and
data ownership belong in [`docs/architecture.md`](../../docs/architecture.md); authentication,
credentials, CSRF, and deletion safety belong in
[`docs/security.md`](../../docs/security.md).

## Character

Quota Web is an editorial account surface: quiet, direct, and precise. It should feel like a useful
open-source tool, not a hosting console or a promotional SaaS dashboard.

- Lead with remaining quota, normalized Usage, and the privacy boundary.
- Use black type, white space, thin neutral rules, and mint only for brand or healthy state.
- Support light and dark appearance. Follow the system until the user chooses one in the footer.
- Prefer clear labels and real values over decoration.
- Do not use gradients, drop shadows, glass effects, fake browser chrome, or ornamental charts.
- Product names are Quota, QuotaBar, and QuotaRelay.

## Shared product vocabulary

Freshness copy, reset copy, the one no-reset phrase, the pace line, provider display names, quota window titles, period names, and Devices copy follow
**Shared product vocabulary** in [`../menubar/DESIGN.md`](../menubar/DESIGN.md); the exact strings
and thresholds are `packages/protocol/fixtures/freshness-copy-conformance.json` and
`packages/protocol/fixtures/quota-pace-conformance.json`, reset copy is
`packages/protocol/fixtures/reset-copy-conformance.json`, and remaining copy is
`packages/protocol/fixtures/remaining-copy-conformance.json`, which `src/lib/format.ts`
answers in its tests. A window's pace prints under its reset line, in `--meter-warn` when the rate
runs the window out before it resets and in the meta color otherwise. The site does not restate
those rules and does not keep a provider or agent name table of its own.

## Information architecture

The site has these routes:

1. `/` is the public landing: a hero (`See what's left across your coding-agent plans.`, a
   supporting sentence that QuotaBar reads locally and Relay syncs remaining quota and Usage
   totals, **Download for macOS**, **Sign in**, `Free & open source · MIT · macOS
   14+`, and three product screenshots), How it works, Providers & agents, Privacy, and
   Platforms. Homebrew is the compact install in the Platforms macOS card: a Homebrew label, a
   short tap note, the `brew install gotry-io/tap/quotabar` command, and a Copy control with
   brief Copied feedback. Sign in is in the hero and the site header. The appearance
   control lives in the footer.
2. `/sign-in` is where every sign-in starts, including the one QuotaBar and Quota for iPhone
   open in a browser. Signed out, it is `Sign in to Quota`, one sentence that an Account is
   reached the same way however you sign in, then the channels in this order: **Continue with
   Apple**, **Continue with GitHub**, and an email field with **Send sign-in link**. Apple and
   GitHub link `/api/auth/<provider>/start?return_to=…`. Apple's button is its own: black with a
   white mark and label in a light appearance, white with a black one in dark, drawn from
   Apple's mark rather than any emoji or substitute glyph, and it does not take the site's ink
   tokens. After a 202, the same page becomes **Check your email** with **Use another way** to
   return to the methods. Signed in, it asks which Account this is: **Continue as \<display
   label\>** and **Use a different account**, which signs this browser out and comes back here.
   When the return is Delete Account (`return_to` carries `delete=account`), the heading is
   **Sign in again to delete your account** and the methods are shown so the session is
   authenticated again — **Continue as** does not refresh `authenticated_at`. `return_to`
   defaults to `/my`, and anything but a same-origin path is a 400. When QuotaBar or Quota for
   iPhone send someone here with `intent=link`, the heading is **Link a sign-in method** and the
   supporting sentence is “Linking adds a way to sign in to the account you're already using; it
   never merges two accounts.” Signed in, the page lists the same bindable channels Settings
   does. Signed out, it offers the usual sign-in methods and `return_to` defaults to
   `/my/settings`. The page is
   `noindex, nofollow`.
3. `/download` is the install page: the same `.dmg` and Homebrew controls as the Platforms macOS card, plus
   requirements (macOS 14 or later, Apple silicon), that QuotaBar updates itself with Sparkle, and
   that Quota for iPhone is coming soon. It does not present an App Store badge or a dead store
   link.
4. `/support` answers FAQ from `src/content/support.md`: where data comes from, when Quota for
   iPhone will be available (Coming soon; when it ships it will read the Account QuotaBar
   reports), how to copy a diagnostic report, and how to delete an account from `/my`.
   Notifications live at `/support#notifications`: remaining-quota alerts and reset reminders
   are configured and evaluated in QuotaBar on the Mac; the website does not send notifications.
5. `/privacy` and `/terms` render `src/content/privacy.md` and `src/content/terms.md`. Both are
   labeled Draft until review. Privacy states what Relay collects and does not collect, who
   processes it, how long it is kept, and how to delete it, from
   [`docs/security.md`](../../docs/security.md).
5. `/u/<handle>` is a published Usage page, and one of the two routes that render account data with
   no session. Its header is the brand plus one **Get Quota** action: no viewer name, no sign-in
   prompt beside someone else's numbers, and no Account nav. The page is a heading (`@handle`,
   when it was published, and **Coding-agent Usage only**) with a **Share** action, then Last 30
   days and All time as three-cell stat rows (Tokens, Messages, and API-equivalent cost when the
   owner published it), each with By provider and By model share bars, then a 365-day activity
   grid drawn from bands rather than counts and with no day detail to open, then one footnote
   saying what stays private. `<head>` carries the canonical URL and Open Graph and Twitter tags
   built from the same summary sentence, so a link preview says what the page says. There is no
   preview image, and so the Twitter card is `summary`: the share card is drawn in the page and
   saved by hand, and no URL serves it. **Share**
   opens a dialog with the 1200×630 card, **Save image**, **Copy link**, and **Close**; the card
   is drawn on a canvas in the page in one Classic style, and there is no server-rendered image.
   The page never prints a device, an agent, a provider sign-in, a plan, a remaining figure, or
   the account label
   ([ADR 0037](../../docs/decisions/0037-a-public-profile-shows-usage-not-quota.md)).
6. `/leaderboard` is the other route rendered with no session, and wears the same published
   header. It is a heading (**Leaderboard**, the window, when it was folded, and **Everyone here
   asked to be listed**), then one table — rank, handle, tokens, messages — of at most a hundred
   rows, each handle linking to `/u/<handle>`, then one footnote saying what the board does not
   rank and where the switch is. The reader's own row is the one thing that differs per reader:
   it takes the brand surface and a **You** badge. Numbers are tabular, the table scrolls inside
   its own container rather than the page, and an empty board says **Nobody is listed yet.**
   There is no cost, model, provider, device, or account label anywhere on it
   ([ADR 0045](../../docs/decisions/0045-the-leaderboard-is-a-page-you-opt-into.md)). The site
   footer links it from every page.
7. `/my` is the signed-in account shell. The site header carries `<nav aria-label="Account">`
   with four routes when the viewer is signed in and the path is under `/my`; the current item
   is `aria-current="page"`. Below 620 px that nav scrolls horizontally and does not wrap. Each
   `/my` page has one `h1` (the page name). Overview's status line is `Latest quota updated
   <age> · <n> devices reporting`, from the newest subscription `observed_at` plus how many
   devices are reporting. Usage's status line is the selected period and whether that period is
   partial. Devices uses the Devices summary line. Settings has no status line. Each route is
   `noindex, nofollow`.
   - `/my` — overview: remaining quota. When the paid-sync entitlement is not `active` or
     `grace`, a static notice `Sync is off. Your Macs stop uploading until you subscribe.`
     links to Settings; it is absent while subscribed. A Subscriptions grid (each card a
     link to `/my/subscriptions/<sel>`), a Today strip (Tokens, API-equivalent cost, and
     today's top model, linking `/my/usage?period=today`), and a one-line Devices summary
     linking `/my/devices`. Next to each provider name, a 6 pt circle in `--meter-warn` (minor)
     or `--meter-critical` (major and critical) with `title` set to the official status-page
     description, from public `GET /api/v2/providers/status`, matching QuotaBar: no dot for
     `none` or `unknown`. `/u/<handle>` does not draw it. Overview does not repeat a cost block
     or an Installations list.
   - `/my/subscriptions/<sel>` — one subscription, visually the same card as Overview: provider
     mark, provider display name, masked account label, plan badge, and the shared freshness
     line; each window with remaining quota, a remaining-percent meter in the shared threshold
     colors, and the reset countdown (`resets_at` re-read every 60 seconds); per-device
     readings from `sources[]`, newest first, with the selected source labelled **Reporting**.
     A selector with no current match reads **This subscription is no longer reported.** The
     page never prints a device id, fingerprint, or subscription key. **← Overview** returns
     to `/my`.
   - `/my/usage` — period tabs (**Today**, **7 Days**, **30 Days**, **Up to 2 years**) on the
     same row as the page `h1`. Totals are three cells: Tokens, API-equivalent cost, and
     Messages (`totals.messages`). At 1024 px and above, the agent → provider → model tree sits
     on the left and Activity (heatmap plus day-detail panel) on the right; below 1024 px those
     stack. The graph is one tab stop (roving tabindex). Choosing a day opens its details under
     the grid and writes `?day=YYYY-MM-DD`. The selected period is `?period=today|7d|30d|all`.
     Under the totals, one line `Priced N of M rows` from that period's cost row counts, or
     `Cost covers every row` / `Cost skips N rows this catalog can't price` when those counts
     are absent.
   - `/my/devices` — a table sorted by last-seen, newest first. Columns: name, platform icon
     (macOS, or a generic device for any other value), Active / Idle / Not reporting (semantic
     color plus the label; Not reporting reads `Paused (no subscription)` when the Account is
     not subscribed), Last contact, and Delete (danger color, existing confirmation).
     Below 620 px each row is a labeled two-column card with Status and Last contact. Empty
     state is the Mac setup card.
   - `/my/settings` — grouped form: Appearance (the same ThemeToggle as the footer); Sync
     (status `Active · renews Oct 5` / `Active · ends Oct 5` / `Grace period · update your
     payment` / `Not subscribed`, with `· last checked <relative>` when the entitlement is
     stale; Subscribe or Manage subscription opens `purchase.web_url` in a new tab); Sign-in
     methods (Apple, GitHub, Email in that order. A bound channel shows its label and
     **Unlink**; the last one is disabled with **Keep at least one way to sign in**, and unlinking
     uses the same ten-minute freshness as Delete Account. An unbound Apple or GitHub is
     **Link** to `/api/auth/<provider>/start?intent=link&return_to=/my/settings`. Unbound Email
     is **Link**, then an inline form `POST /api/auth/email/start` with `intent: "link"`, then
     **Check your email**. `?linked=taken` shows **That account is already linked to another
     Quota account.** once at the top of the page and then drops the query); Account (the
     display label and Delete Account); Public profile; Legal. `?delete=account` scrolls to the
     delete region and focuses its heading. Legal links Privacy, Terms, and Support. Sign out
     stays in the header account menu. Public profile is the handle field (prefixed
     `quota.gotry.io/u/`), **Publish this page**, **Show which models**, **Show API-equivalent
     cost**, **Show on the leaderboard** (disabled until the page is published, and cleared with
     it), one **Save**, and — once published — **Open page** and **Copy link**. A handle the
     contract refuses is named before the request is made; one another Account holds reads **That
     handle is already taken.** Switching the page off keeps the handle.
   Quota remaining has no "left"/"remaining" suffix; usd/credits remaining of a cap use
   `$12.50 of $40.00` without a meter; other budget windows with an amount use `71% · $3.75`;
   percent-only windows use `71%`; and balance-only windows use **Balance** plus `$12.34`.
   Quota cards follow the same provider / account / remaining / meter / metadata order
   as QuotaBar Overview, in a denser web layout. The card head is the provider mark
   (`/providers/*.svg`, or a first-letter color block), provider name, plan badge, and masked
   account; each window is a row of name, remaining-percent meter, percent, and `Resets in 45m`;
   the foot is `Studio Mac · 1m ago`. Quota cards share `.quota-grid`: two columns on
   desktop and one column below 620 px. Cursor's Other Models percentage and included-usage
   dollar amount are separate provider meters: compact Quota cards show only the percentage; the
   subscription detail page shows both. Empty quota states span the full row and show the Mac
   setup sentence once. Selecting an Activity day loads that day's Usage under the grid. The
   header account menu shows a first-letter mark and login; the menu contains **Settings** and
   **Sign out**. Session cookies stay HttpOnly. SvelteKit renders the header from
   `WebDocumentPort.getViewer` on the first HTML byte. The `/my` document is a signed-in shell
   and does not carry Account data: one client store holds the summary, activity (keyed by
   `from|to`), and per-day detail, and loads `GET /api/v6/account/summary` with the browser's IANA
   timezone. The account shell re-runs `ensureSummary()` on account navigations without blocking
   first paint or replacing cached data with a skeleton. Usage loads and revalidates activity
   when that route is entered. The activity range is a UTC date taken from the 60-second display
   clock, so the cache key and fetch change at the UTC day boundary even if the page stays open;
   minutes within the same UTC day do not refetch. Fresh reads are reused for 60 seconds
   (stale-while-revalidate); an immediate tab switch does not refetch. Unsigned
   visits to `/my` and its sub-routes are a server redirect to `/`. The shipped `/app` bookmark
   is a single redirect to `/my`. Account data is never published without a session.

The document `<head>` is per-route. `/` publishes the public title, description, canonical URL
`https://quota.gotry.io/`, and Open Graph tags. `/u/<handle>` and `/leaderboard` publish their own
canonical URL and Open Graph tags, each built from the same summary sentence the page states.
`/my` is `noindex, nofollow` and has no canonical URL.

Signing in is the only account action the marketing pages take. There is no Relay selection,
pairing group, owner capability, provider-secret form, server administration, or self-hosted setup
in the Web UI.

## Tokens

Tokens are defined in `src/app.css` and must remain the source used by the implementation.

### Color

| Role | Light | Dark | Use |
| --- | --- | --- | --- |
| Ink | `#000000` | `#f4f4f4` | Primary type and primary actions |
| Deep ink | `#090909` | `#ffffff` | Primary-action hover |
| Charcoal | `#525252` | `#c4c4c4` | Secondary labels and navigation |
| Body | `#737373` | `#a3a3a3` | Supporting prose |
| Muted | `#6b6b6b` | `#8f8f8f` | Tertiary metadata; 4.5:1 or better on the canvas in both themes |
| Emerald / mint | `#087456` / `#82ddb8` | `#82ddb8` | Brand and healthy/complete meaning |
| Brand surface | `#f2f8f5` | `#10231c` | Quiet highlighted regions |
| Canvas | `#ffffff` | `#111111` | Page and cards |
| Soft surface | `#fafafa` | `#1b1b1b` | Hover and low-contrast grouping |
| Inverted surface | `#171717` | `#f4f4f4` | Bounded opposite-tone section |
| Hairline | `#e5e5e5` | `#2a2a2a` | Dividers and card outlines |

Color never carries status alone. Every state also has a text label. The footer has one conventional
appearance control with **System**, **Light**, and **Dark** options. System is the default, leaves no
`data-theme` override, and follows the browser's `color-scheme` immediately when the operating-system
appearance changes. Light or Dark writes the explicit `quota-theme` override to local storage;
choosing System removes it. Do not render three permanent footer buttons.

### Type

- Body and controls: `Inter`, then the native sans-serif stack.
- Display headings: `ui-rounded`, `SF Pro Rounded`, then the system stack.
- The hero uses a responsive `clamp(36px, 5vw, 56px)` display size with compact leading.
- Body copy stays between 16 and 21 px with generous line height.
- Account-shell type uses `--fs-h1` (32 px desktop / 28 px below 620 px), `--fs-h2` (20 px),
  `--fs-body` (15 px), and `--fs-caption` (13 px) from `src/app.css`.
- Monospace is reserved for values whose literal representation matters, such as authorization
  codes. Do not use it as a decorative product motif.

### Meter thresholds

Remaining-percent meters use `--meter-good` at 40 and above, `--meter-warn` from 15 through 39,
and `--meter-critical` below 15, in both appearances — the same bands as QuotaBar's
`QuotaUsageTone`. Color never carries status alone: the percent
label stays next to the bar.

### Shape and spacing

- Content width is at most 1120 px with a 24 px minimum page gutter.
- Cards use a 1 px hairline and 12 px radius.
- Primary and secondary buttons are pill-shaped, at least 42 px high.
- Sections use large vertical gaps; dense data groups use 12–24 px gaps.
- Destructive actions are text-first and require an explicit confirmation.

## Landing page

The landing is six blocks, in this order. It does not use slogan sections.

1. **Hero.** The `h1` is “See what's left across your coding-agent plans.” One supporting
   sentence: “QuotaBar reads your providers on the Mac; Relay syncs only remaining quota and
   Usage totals to the web.” Dual CTAs: **Download for macOS** (the live GitHub Releases `.dmg`)
   and **Sign in** (`/sign-in`), with `Free & open source · MIT ·
   macOS 14+` beside them. The product preview is three real screenshots, not a hand-coded
   mock: QuotaBar overview, the account overview (desktop capture), and Quota for iPhone
   overview labelled **Preview**. Each shot has a light and dark asset switched from
   `html[data-theme]`, using `prefers-color-scheme` only when there is no explicit theme.
   Images declare `width` and `height`. Below 620 px the preview is a featured Web image plus a
   horizontal snap gallery; each image is at least 280 px wide. The shots show remaining quota
   — provider, plan, window, percent, meter, reset, and freshness — and do not lead with a
   monthly spend figure.
2. **How it works.** Three steps: Install QuotaBar; it reads your providers locally; the web
   shows the same numbers.
3. **Providers & agents.** A grid names every catalog provider (with its mark) and every
   billing agent. Those names come from `packages/provider/catalog.json` and
   `agentDisplayName`, not from a page-local table.
4. **Privacy.** “What never leaves your Mac,” three points: provider credentials, prompts, and
   local paths never leave the Mac; Quota uploads remaining quota and privacy-preserving Usage
   totals only; a link to `/privacy`.
5. **Platforms.** Three cards. macOS is QuotaBar: the `.dmg` download plus Homebrew as a
   hairline or neutral-surface secondary install — no fake terminal, gradient, or shadow. The
   command is monospace; Copy announces a short Copied state through `aria-live`. Narrow
   viewports stack or scroll the command safely without overflowing the page. Web is Sign in
   with GitHub. iPhone status is `IOS_AVAILABILITY` in `src/lib/platforms.ts`
   (`coming-soon` | `testflight` | `app-store`, default `coming-soon`). Copy is `iPhone app
   coming soon` while that default holds. The type may carry optional `url` and `actionLabel`;
   render **Join TestFlight** or **View in App Store** only when `url` is set. Do not present a
   dead store link.
6. **Footer.** `© {year} GoTry IO · MIT`, links for Leaderboard, Download, Support, Privacy,
   Terms, GitHub, and Account, and the appearance toggle in a controls group. The toggle keeps a visible
   focus ring and a 42 px target.

## Account dashboard

The signed-in shell is `/my` with four routes — overview, Usage, Devices, and Settings — and one
Account nav in the site header. The overview leads with remaining quota: when sync is off, a static
notice `Sync is off. Your Macs stop uploading until you subscribe.` with a Settings link, then
subscription cards (a 6 pt incident dot beside the provider name when official status is minor or
worse), then a Today strip (tokens, API-equivalent cost, today's top model), then a
Devices summary line (`2 devices · all reporting` or `1 of 2 reporting`, plus the worst Device's
verdict). It does not repeat a cost block or an Installations list. The notice is absent while the
entitlement is `active` or `grace`. Under Usage, period tabs sit on the same row as the
page name. Totals are three cells: tokens, API-equivalent cost — the same headline QuotaBar and iOS
show — and Messages from `totals.messages`. The input/output split stays under the token figure.
Cost always says how it was arrived at; unavailable cost renders as an em dash plus “Unpriced”, and
partial cost uses a lower bound marker. Under the totals headline, one line `Priced N of M rows`
from that period's cost row counts, or `Cost covers every row` / `Cost skips N rows this catalog
can't price` when those counts are absent. The Usage page period tabs are **Day**, **Week**, **Month**,
**7D**, **30D**, **All**, and **Custom** — the abbreviations of the names in Shared product
vocabulary, which are also their accessible names; **Last 30 days** is the default. Under the tabs
sit **Previous period**, the range title, and **Next period**; the arrows apply to Day, Week, and
Month only, and **Next period** is disabled on the current unit. **Custom** opens two native date
inputs bounded by the activity range and an **Apply**. The selection is
`?period=day|week|month|7d|30d|all|custom`, plus `&offset=` on a stepped period and `&from=&to=` on
a custom one, so a refresh keeps it. Today, 7D, 30D, and All are read from the Account summary;
every other period is folded in the browser from the activity days the page already holds, so it
shows totals and cost and says in one line that the model breakdown is on the four the summary
carries.

Above the totals is a **Monthly budget** card: an amount in USD, a **Tell me at 80% and 100%**
switch, and a meter reading `spent / budget · percent` against this month's fold. Both fields live
in `localStorage` and never reach Relay. Crossing 80% and then 100% shows one `role="status"` line
each per calendar month with a **Got it** button that records the crossing, because a browser page
posts no notification. With no budget set the card reads **No budget is set for this month.**

At 1024 px and above the model tree and Activity
sit side by side; below 1024 px they stack, tree first. User-facing dates, numbers, units, and
plan names use the English presentation shared with QuotaBar rather than the browser locale.
Usage activity is a GitHub-style contribution graph that still follows this file: no gradients,
shadows, or glass. Weeks are Sunday-first columns. The left axis shows Mon, Wed, and Fri. Month
labels sit on the Sunday-first week that contains that month’s first visible in-range day, then
are dropped when they would overlap. In-range days are buttons; padding days stay inert. The graph is a group (`role="group"`,
`aria-roledescription="grid"`) with one tab stop: only the active day is `tabindex="0"`, the rest
are `-1`. Arrow keys move the active day — left and right by one day, up and down by one week.
Home and End move to the first and last in-range day of that week; Page Up and Page Down move by
30 days. Enter or Space opens the focused day. `aria-label` is the full UTC date, token total, and
estimated cost; `aria-pressed` marks the selected day. Cell fill still maps token volume to
highlight levels. Today keeps a distinct ink outline. Hover and keyboard focus scale a cell about
1.35× with a raised z-index and no layout shift; `prefers-reduced-motion` disables the transition.
A visible tooltip appears immediately on pointer hover and keyboard focus with the full UTC date,
token total, and API-equivalent estimated cost, including Unpriced and priced-subset-only wording.
It follows the active cell, is not clipped by the graph’s horizontal scroller, does not scale with
the cell, and stays inside the viewport so it cannot overflow the page. Leave and blur hide it.
Narrow viewports scroll the graph horizontally so weekday labels stay readable and the page does
not overflow.

Choosing a day — click, Enter, or Space — opens an inline details panel under the Activity card,
not a modal, and writes `?day=YYYY-MM-DD` so a refresh keeps it. Close removes the query and
returns focus to that day's cell. The dashboard owns selected, loading, error, and data state. The
panel shows that day's UTC date, tokens, input/output, messages, estimated cost and its basis, and
whether any hour behind it was scanned incompletely, from the activity range it already holds. The
agent tree is a second read:
`GET /api/v6/account/usage/activity?from=D&to=D&detail=agents`. Loading uses a skeleton; a failed
Relay response uses the same retry notice as the rest of the dashboard. An empty `agents` list
reads **No Usage on this day.** A 401 starts GitHub sign-in. The dashboard does not repeat the
GitHub username in the page heading; the header account menu is the identity.

Quota cards show one subscription, not one upload: an account collected on several Macs is one card
carrying the reading that still describes it, with the reporting device and age on the foot
(`Studio Mac · 1m ago`). A reading that aged out names why — **Not current — last reading 2d ago**
— rather than as a current number, so the card needs no separate status pill. Other reporting
devices stay on the subscription detail page.

The subscription detail page is `/my/subscriptions/<sel>`. Its header matches an Overview card:
provider mark, provider name from the catalog, masked account label, and plan badge, then the
shared freshness line, then each window with remaining quota, a meter in the shared threshold
colors, and the reset countdown. A passed refill instant prints no Resets line. `sources[]`
are listed newest first as the Device display name (or **Device** when that Device is gone), that
reading's primary remaining figure, and freshness; the selected source is labelled **Reporting**.
Nothing on the page prints a device id, fingerprint, or subscription key. A selector that matches
no current row reads **This subscription is no longer reported.** **← Overview** returns to `/my`.

The Devices table is sorted by last-seen, newest first. Each row is display name, a macOS platform
icon (or a generic device for any other value), an **Active** / **Idle** / **Not reporting** pill
(semantic color plus the label; **Paused (no subscription)** in place of Not reporting when the
Account is not subscribed), Last contact, and Delete. Below 620 px each row is a labeled
two-column card. Never a claim that a sleeping or closed app failed, never raw Device IDs, and
never a request that the viewing browser fix another Device's provider credentials. Deletion copy
must say that both the Device and its Quota/Usage data are removed. Empty Devices is the Mac setup
card. Settings is a grouped form: Appearance; Sync (status `Active · renews Oct 5` / `Active ·
ends Oct 5` / `Grace period · update your payment` / `Not subscribed`, plus `· last checked
<relative>` when stale; **Subscribe** or **Manage subscription** opens the RevenueCat Web Purchase
Link in a new tab); Sign-in methods (Apple, GitHub, Email; bound label plus **Unlink**, last
**Unlink** disabled with **Keep at least one way to sign in**; unbound **Link** or the Email
form); Account (display label and Delete Account, with `?delete=account` focusing the delete
heading); Legal (Privacy, Terms, Support). Sign out stays in the header account menu.
Notification rules are documented at `/support#notifications`.

The Usage totals card carries five tiles: Tokens, API-equivalent cost, Messages, Cache hit, and
Reasoning. Cache hit is whole percent with `saved $X.XX` under it, or **—** with **Nothing priced to
compare** when the period's cache reads could not be priced
([ADR 0036](../../docs/decisions/0036-usage-derived-metrics.md)). At 640 px the card is one column.

Under it, for every period but **Up to 2 years**, a **Daily** panel: one bar per UTC day of the
period, a **Tokens** / **Cost** pair of `aria-pressed` text buttons deciding what they measure, and
a **Show daily breakdown** disclosure over a semantic table with Date / Total / In / Out / Cached /
Reasoning / Messages / Cost. In Tokens the bar stacks cached input, fresh input, and output, which
add up to the day's total, using the three darkest activity steps; a day with nothing in it is drawn
in `--activity-0` rather than left out. The panel is labelled **UTC**, the calendar the activity
read answers. **Up to 2 years** has no Daily panel: its per-day shape is the Activity graph beside
it.

Under Daily, for every period but **Up to 2 years**, a **Rhythm** panel: a Sunday-first weekday ×
hour heatmap using the same `--activity-0`…`--activity-4` steps as the Activity graph, then 24 bars
for the hour-of-day totals. The period's URL parameters select the range; the read is
`GET /api/v6/account/usage/activity?from&to&detail=hours&tz=` in this browser's zone. Omit the
panel when every hour is empty. The public page `/u/<handle>` has no Rhythm.

Agent Usage is an agent → provider → model tree in a semantic table: a caption, Model / Tokens /
Share / Cost column headers, and one `<tbody>` per agent. Above it sit the three largest models as
an ordered list of `share · tokens`, and one share bar per provider. Group title rows
(`<th scope="rowgroup">`) name the agent, then each inference provider. Model rows follow; the
`other` fold bucket reads **Other**.
Each provider shows five models and a **Show N more** / **Show fewer** control (`aria-expanded`)
for the rest. A
period with no agents reads **No Usage in this period.** Empty and loading states use a skeleton
(`aria-busy`); a failed Relay response is **Your session ended. Sign in again.** (401), **Sign in
again to confirm this change.** or **You don't have permission to do that.** (403), or **Quota
couldn't load this. Retry.** — at most one next action.

## Responsive behavior

- At 1024 px, Usage is two columns (model tree · Activity). Below 1024 px those stack, tree first.
- At 840 px, two-column hero and architecture layouts become one column.
- At 620 px, the page gutter reduces, header navigation hides nonessential links, the Account
  nav scrolls horizontally without wrapping, actions become full width where useful, summary
  and quota grids stack to one column, the landing preview becomes a featured Web image plus a
  horizontal snap gallery with images at least 280 px wide, and Devices rows become two-column
  cards. The Activity graph scrolls horizontally inside its card; weekday labels stay readable.
  The header account session control and the footer appearance toggle stay visible.
- The layout must work from 320 px upward without clipped actions or horizontal page scrolling.

## Accessibility and motion

- Use landmarks, one page-level `h1`, ordered headings, semantic tables, labels, and native buttons.
- Keep a keyboard-visible 3 px emerald focus ring and a functional skip link.
- Interactive targets are at least 42 px high; destructive confirmation is keyboard reachable.
- Notices use `role=status` or `role=alert` according to urgency.
- Respect `prefers-reduced-motion`; animation is optional and never required to understand state.
- Maintain WCAG AA contrast for text and controls.

## Acceptance

Before shipping a Web change:

- run the package check and production build;
- inspect `/`, `/download`, `/support`, `/privacy`, `/terms`, `/u/<handle>`, `/leaderboard`, `/my`,
  `/my/subscriptions/<sel>`, `/my/usage`, `/my/devices`, `/my/settings` (and the shipped `/app`
  redirect) at desktop and narrow mobile widths in both light and dark appearance when browser
  tooling is available;
- navigate all controls with a keyboard;
- verify loading, signed-out, empty, partial/unpriced cost, recent-auth, and failure states;
- confirm no credential, raw Usage, prompt, path, or untrusted HTML reaches the DOM.
