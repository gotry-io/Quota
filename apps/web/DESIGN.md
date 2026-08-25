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

## Information architecture

The site has four surfaces:

1. `/` explains local collection, one GitHub-backed Account, Devices, and API-equivalent Usage cost.
   The hero offers a QuotaBar `.dmg` download as the primary action. Homebrew is a compact
   secondary install under that CTA: a Homebrew label, a short tap note, the
   `brew install gotry-io/tap/quotabar` command, and a Copy control with brief Copied feedback.
   GitHub sign-in lives only in the site header. The appearance control lives in the footer.
2. `/my` is the signed-in dashboard: compact remaining-quota cards, account totals, cost coverage,
   Usage activity, model/agent breakdowns, Devices, and explicit Device deletion. Quota remaining
   has no "left"/"remaining" suffix; budget windows with an amount use `71% · $3.75`, percent-only
   windows use `71%`, and balance-only windows use **Balance** plus `$12.34`. Quota cards follow
   the same provider / account / remaining / meter / metadata order as QuotaBar Overview, in a
   denser web layout. Quota cards share `.quota-grid`: two columns on desktop and one column
   below 620 px. Cursor's Other Models percentage and included-usage dollar amount are separate
   provider meters: compact Quota cards show only the percentage while retaining the amount in the
   typed response for a future detail surface. Empty quota states span the full row. Selecting an Activity day loads that
   day's Usage under the grid. The header shows the GitHub username;
   the name opens `/my`, and its menu
   contains only **Sign out**. Session cookies stay HttpOnly. SvelteKit renders the header from
   `WebDocumentPort.getViewer` on the first HTML byte. While rendering the signed-in document, the
   Worker starts `GET /api/v5/account/summary` internally, reuses the resolved Better Auth session,
   and streams the typed result into the page. The browser fetch is only a development or retry
   path; it is not the production first-load path. Unsigned visits to `/my` are a server redirect to
   `/`. A successful `/u/{slug}` page view consumes two `public-profile` limiter tokens (document
   existence plus the JSON payload); after 60 views / 10 minutes the HTML can remain 200 while the
   JSON returns 429. The shipped `/app`
   bookmark is a single redirect to `/my`. Every signed-in GitHub account is public at
   `/u/{github-username}`. The dashboard has no public-page visibility control.
3. `/u/{username}` is the public remaining-quota and usage view for that GitHub username. It shows
   one card per subscription, the same unit the dashboard shows, so a provider with two accounts
   reads as two cards rather than one silently chosen for the viewer; a reading that is no longer
   current is not published at all. It never includes device ids, fingerprints, credentials, or
   private identifiers, so two cards of one provider are told apart by their plan and numbers.
   Unknown usernames show a plain unavailable state.
4. `/activate` approves or denies a released native-client device authorization code.

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
| Muted | `#a3a3a3` | `#737373` | Tertiary metadata |
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
- Monospace is reserved for values whose literal representation matters, such as authorization
  codes. Do not use it as a decorative product motif.

### Shape and spacing

- Content width is at most 1120 px with a 24 px minimum page gutter.
- Cards use a 1 px hairline and 12 px radius.
- Primary and secondary buttons are pill-shaped, at least 42 px high.
- Sections use large vertical gaps; dense data groups use 12–24 px gaps.
- Destructive actions are text-first and require an explicit confirmation.

## Landing page

The hero headline is “Know what you have left.” Its primary action is the QuotaBar `.dmg`
download and its secondary action scrolls to the product explanation. GitHub sign-in is only
in the header. The product preview may show representative account Usage, but it must label the
cost as API-equivalent and state that unknown prices remain unpriced.

The explanation follows this order:

- local collection and what never uploads;
- one Account with Device visibility;
- defensible, effective-dated cost;
- the direct local agent logs → QuotaBar local service → Account data path.

The hero presents the live GitHub Releases `.dmg` first. Homebrew sits below it as a hairline
or neutral-surface secondary install: no fake terminal, gradient, or shadow. The command is
monospace; Copy announces a short Copied state through `aria-live`. Narrow viewports stack or
scroll the command safely without overflowing the page. Do not present unavailable downloads
or documentation as active destinations.

The footer shows `© {year} GoTry IO · MIT`, repository and account links, and the appearance
toggle in a controls group. The toggle keeps a visible focus ring and a 42 px target.

## Account dashboard

The dashboard leads with input tokens, output tokens, and API-equivalent cost. Cost always shows its
coverage/basis; unavailable cost renders as an em dash plus “Unpriced”, and partial cost uses a lower
bound marker. It reads all retained Account Usage by default. User-facing dates, numbers, units, and
plan names use the English presentation shared with QuotaBar rather than the browser locale.
Usage activity is a GitHub-style contribution graph that still follows this file: no gradients,
shadows, or glass. Weeks are Sunday-first columns. The left axis shows Mon, Wed, and Fri. Month
labels sit on the Sunday-first week that contains that month’s first visible in-range day, then
are dropped when they would overlap. In-range days are focusable buttons; padding days stay inert.
Cell fill still maps token volume to highlight levels. Today keeps a distinct ink outline. The
selected day uses `aria-pressed`. Hover and keyboard focus scale a cell about 1.35× with a raised
z-index and no layout shift; `prefers-reduced-motion` disables the transition. A visible tooltip
appears immediately on pointer hover and keyboard focus with the full UTC date, token total, and
API-equivalent estimated cost, including Unpriced and priced-subset-only wording. It is not clipped
by the graph’s horizontal scroller, does not scale with the cell, and stays inside the viewport so
it cannot overflow the page. Leave and blur hide it. Narrow viewports scroll the graph horizontally
so weekday labels stay readable and the page does not overflow.

Choosing a day opens an inline details panel under the Activity card, not a modal. The dashboard
owns selected, loading, error, and data state and fetches
`GET /api/v5/account/usage/summary?usage_agents=all&cost_mode=calculate&model_catalog=1&from=YYYY-MM-DD&to=YYYY-MM-DD`,
reusing the existing `usage_date` timezone. A 401 starts GitHub sign-in. Failures stay on the
page with a retry control. The panel can be closed. It shows that day's date, input, output,
requests, estimated cost, coverage, and compact agent and model splits, with honest empty,
truncated, partial, and unpriced copy. The dashboard does not repeat the GitHub username in the
page heading.

Quota cards show one subscription, not one upload: an account collected on several Macs is one card
carrying the reading that still describes it, with the reporting device and observation time below
it and the other reporting devices named on a second line. The status pill uses the shared
observation vocabulary, so a reading that aged out reads as Stale rather than as a current number.

Device cards show display name, platform, app product/version, and compact last
report/refresh/sync. A server-fresh healthy/current-or-empty report with no required or optional
attention is **Healthy**; fresh problem states are **Needs attention** or **Check device** and direct
the user to Diagnostics on that Device. Expired or absent reports are **Not recently active** or
**Unknown**, not an assertion that a sleeping or closed app failed. Lifecycle **Signed out** remains
explicit. Never show raw Device IDs or ask the viewing browser/device to fix another Device's
provider credentials. Deletion copy must say that both the Device and its Quota/Usage data are
removed. Agent Usage uses a semantic table with real column headers. Empty, loading,
unauthenticated, recent-auth-required, and service-error states use plain explanatory text and one
next action.

## Device authorization

`/activate` is a single-task form. It explains that approval issues Account-read and current-Device
upload sessions without sharing provider credentials. The code input supports one-time-code
autofill. Approve is primary; Deny is secondary. Success tells the user to return to the requesting
Quota client.

## Responsive behavior

- At 840 px, two-column hero and architecture layouts become one column.
- At 620 px, the page gutter reduces, navigation hides nonessential links, actions become full
  width where useful, summary and quota grids stack to one column, and data tables remain
  horizontally scrollable. The Activity graph scrolls horizontally inside its card; weekday
  labels stay readable. The header account session control and the footer appearance toggle
  stay visible.
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
- inspect `/`, `/my` (and the shipped `/app` redirect), and `/activate` at desktop and narrow mobile
  widths in both light and dark appearance when browser tooling is available;
- navigate all controls with a keyboard;
- verify loading, signed-out, empty, partial/unpriced cost, recent-auth, and failure states;
- confirm no credential, raw Usage, prompt, path, or untrusted HTML reaches the DOM.
