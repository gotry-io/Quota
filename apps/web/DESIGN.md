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

Freshness copy, reset copy, the one no-reset phrase, provider display names, quota window titles, period names, and Devices copy follow
**Shared product vocabulary** in [`../menubar/DESIGN.md`](../menubar/DESIGN.md); the exact strings
and thresholds are `packages/protocol/fixtures/freshness-copy-conformance.json`, which
`src/lib/format.ts` answers in its tests. The site does not restate those rules and does not keep a
provider or agent name table of its own.

## Information architecture

The site has these routes:

1. `/` is the public landing: a hero (value sentence, **Download for macOS**, **Sign in with
   GitHub**, and three product screenshots), How it works, Providers & agents, Privacy, and
   Platforms. Homebrew is the compact install in the Platforms macOS card: a Homebrew label, a
   short tap note, the `brew install gotry-io/tap/quotabar` command, and a Copy control with
   brief Copied feedback. GitHub sign-in is in the hero and the site header. The appearance
   control lives in the footer.
2. `/download` is the install page: the same `.dmg` and Homebrew controls as the Platforms macOS card, plus
   requirements (macOS 14 or later, Apple silicon), that QuotaBar updates itself with Sparkle, and
   that Quota for iPhone is coming soon. It does not present an App Store badge or a dead store
   link.
3. `/support` answers FAQ from `src/content/support.md`: where data comes from, why iPhone has no
   data until a Mac running QuotaBar has signed in, how to copy a diagnostic report, and how to
   delete an account from `/my`.
4. `/privacy` and `/terms` render `src/content/privacy.md` and `src/content/terms.md`. Both are
   labeled Draft until review. Privacy states what Relay collects and does not collect, who
   processes it, how long it is kept, and how to delete it, from
   [`docs/security.md`](../../docs/security.md).
5. `/my` is the signed-in account shell. The site header carries `<nav aria-label="Account">`
   with four routes when the viewer is signed in and the path is under `/my`; the current item
   is `aria-current="page"`. Below 620 px that nav scrolls horizontally and does not wrap. Each
   `/my` page has one `h1` (the page name) and a status line from the Account summary:
   `Updated <age> · <n> devices reporting`, using the shared freshness copy. Each route is
   `noindex, nofollow`.
   - `/my` — overview: remaining quota. A Subscriptions grid (each card a link to
     `/my/subscriptions/<sel>`), a Today strip (Tokens, API-equivalent cost, and the 30-day
     top model, linking `/my/usage?period=today`), and a one-line Devices summary linking
     `/my/devices`. Overview does not repeat a cost block or an Installations list.
   - `/my/subscriptions/<sel>` — one subscription: provider display name, masked account
     label, plan badge, and the shared freshness line; each window with remaining quota, a
     meter, and the reset countdown (`resets_at` re-read every 60 seconds); per-device
     readings from `sources[]`, newest first, with the selected source labelled **Reporting**.
     A selector with no current match reads **This subscription is no longer reported.** The
     page never prints a device id, fingerprint, or subscription key. **← Overview** returns
     to `/my`.
   - `/my/usage` — Totals (period tabs, Tokens and API-equivalent cost, an agent → provider →
     model tree) and Activity. The graph is one tab stop (roving tabindex). Choosing a day
     opens its details under the grid and writes `?day=YYYY-MM-DD`.
   - `/my/devices` — Device cards and Device deletion.
   - `/my/settings` — appearance (the same ThemeToggle as the footer, as one row) and Delete
     Account. `?delete=account` scrolls to the delete region and focuses its heading.
   Quota remaining has no "left"/"remaining" suffix; budget windows with an amount use
   `71% · $3.75`, percent-only windows use `71%`, and balance-only windows use **Balance** plus
   `$12.34`. Quota cards follow the same provider / account / remaining / meter / metadata order
   as QuotaBar Overview, in a denser web layout. The card head is the provider mark
   (`/providers/*.svg`, or a first-letter color block), provider name, plan badge, and masked
   account; each window is a row of name, remaining-percent meter, percent, and `Resets in 45m`;
   the foot is `Studio Mac · 1m ago`. Quota cards share `.quota-grid`: two columns on
   desktop and one column below 620 px. Cursor's Other Models percentage and included-usage
   dollar amount are separate provider meters: compact Quota cards show only the percentage; the
   subscription detail page shows both. Empty quota states span the full row and show the Mac
   setup sentence once. Selecting an Activity day loads that day's Usage under the grid. The
   header account menu shows the GitHub avatar (`https://github.com/<login>.png?size=64`, or a
   first-letter mark when the viewer has no login) and login; the menu contains **Settings** and
   **Sign out**. Session cookies stay HttpOnly. SvelteKit renders the header from
   `WebDocumentPort.getViewer` on the first HTML byte. The `/my` document is a signed-in shell
   and does not carry Account data: one client store holds the summary, activity (keyed by
   `from|to`), and per-day detail, loads `GET /api/v6/account/summary` with the browser's IANA
   timezone, then prefetches a year of activity without blocking first paint. Fresh reads are
   reused for 60 seconds (stale-while-revalidate); switching tabs does not refetch. Unsigned
   visits to `/my` and its sub-routes are a server redirect to `/`. The shipped `/app` bookmark
   is a single redirect to `/my`. Account data is never published without a session.

The document `<head>` is per-route. `/` publishes the public title, description, canonical URL
`https://quota.gotry.io/`, and Open Graph tags. `/my` is `noindex, nofollow` and has no canonical
URL.

GitHub is the only sign-in action. There is no Relay selection, pairing group, owner capability,
provider-secret form, server administration, or self-hosted setup in the Web UI.

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
- The hero uses a responsive 52–84 px display size with compact leading.
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

1. **Hero.** The `h1` is “See what's left on every coding-agent plan — Codex, Claude, Grok,
   Cursor — in your Mac menu bar, on the web, and on iPhone.” Dual CTAs: **Download for macOS**
   (the live GitHub Releases `.dmg`) and **Sign in with GitHub** (`/api/auth/github/start`).
   The product preview is three real screenshots, not a hand-coded mock: QuotaBar overview,
   the account overview (desktop capture), and Quota for iPhone overview, each with a light
   and dark asset selected by `prefers-color-scheme`. Images declare `width` and `height`. The
   shots show remaining quota — provider, plan, window, percent, meter, reset, and freshness —
   and do not lead with a monthly spend figure.
2. **How it works.** Three steps: Install QuotaBar; it reads your providers locally; web and
   iPhone show the same numbers.
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
   (`coming-soon` | `testflight` | `app-store`, default `coming-soon`). The card shows that
   label as a badge. Do not present an App Store or TestFlight destination until that constant
   names a live one; do not present a dead store link.
6. **Footer.** `© {year} GoTry IO · MIT`, links for Download, Support, Privacy, Terms, GitHub,
   and Account, and the appearance toggle in a controls group. The toggle keeps a visible
   focus ring and a 42 px target.

## Account dashboard

The signed-in shell is `/my` with four routes — overview, Usage, Devices, and Settings — and one
Account nav in the site header. The overview leads with remaining quota: subscription cards, then a
Today strip (tokens, API-equivalent cost, 30-day top model), then a Devices summary line
(`2 devices · all reporting` or `1 of 2 reporting`, plus the oldest Device's verdict). It does not
repeat a cost block or an Installations list. Under Usage, totals lead with tokens and API-equivalent
cost — the same headline QuotaBar and iOS show — with the input/output split as supporting detail.
Cost always says how it was arrived at; unavailable cost renders as an em dash plus “Unpriced”, and
partial cost uses a lower bound marker. The Usage page period tabs are **Today**, **7 Days**,
**30 Days**, and **Up to 2 years** (`all`); **30 Days** is the default. The selected tab is
`?period=today|7d|30d|all`, so a refresh keeps it. User-facing dates, numbers, units, and
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
panel shows that day's UTC date, tokens, input/output, requests, estimated cost and its basis, and
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

The subscription detail page is `/my/subscriptions/<sel>`. It names the provider from the catalog,
the masked account label, the plan, and the shared freshness line, then each window with remaining
quota, a meter, and the reset countdown. A passed refill instant prints no Resets line. `sources[]`
are listed newest first as the Device display name (or **Device** when that Device is gone), that
reading's primary remaining figure, and freshness; the selected source is labelled **Reporting**.
Nothing on the page prints a device id, fingerprint, or subscription key. A selector that matches
no current row reads **This subscription is no longer reported.** **← Overview** returns to `/my`.

Device cards show display name, an **Active** / **Idle** / **Not reporting** pill, and one line of
platform plus the age that verdict came from. Never a claim that a sleeping or closed app failed,
never raw Device IDs, and never a request that the viewing browser fix another Device's provider
credentials. Deletion copy must say that both the Device and its Quota/Usage data are removed. Agent
Usage is an agent → provider → model tree in a semantic table: a caption, Model / Tokens / Cost
column headers, and one `<tbody>` per agent. Group title rows (`<th scope="rowgroup">`) name the
agent, then each inference provider. Model rows follow; the `other` fold bucket reads **Other**.
Each provider shows five models and a **Show N more** control (`aria-expanded`) for the rest. A
period with no agents reads **No Usage in this period.** Empty and loading states use a skeleton
(`aria-busy`); a failed Relay response is **Your session ended. Sign in again.** (401), **Sign in
again to confirm this change.** or **You don't have permission to do that.** (403), or **Quota
couldn't load this. Retry.** — at most one next action.

## Responsive behavior

- At 840 px, two-column hero and architecture layouts become one column.
- At 620 px, the page gutter reduces, header navigation hides nonessential links, the Account
  nav scrolls horizontally without wrapping, actions become full width where useful, summary
  and quota grids stack to one column, and data tables remain horizontally scrollable. The
  Activity graph scrolls horizontally inside its card; weekday labels stay readable. The header
  account session control and the footer appearance toggle stay visible.
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
- inspect `/`, `/download`, `/support`, `/privacy`, `/terms`, `/my`, `/my/subscriptions/<sel>`,
  `/my/usage`, `/my/devices`, `/my/settings` (and the shipped `/app` redirect) at desktop and
  narrow mobile widths in both light and dark appearance when browser tooling is available;
- navigate all controls with a keyboard;
- verify loading, signed-out, empty, partial/unpriced cost, recent-auth, and failure states;
- confirm no credential, raw Usage, prompt, path, or untrusted HTML reaches the DOM.
