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
- Support light and dark appearance. Follow the system until the user chooses one in the header.
- Prefer clear labels and real values over decoration.
- Do not use gradients, drop shadows, glass effects, fake browser chrome, or ornamental charts.
- Product names are Quota, QuotaBar, and QuotaRelay.

## Information architecture

The site has four surfaces:

1. `/` explains local collection, one GitHub-backed Account, Devices, and API-equivalent Usage cost.
   The hero offers a QuotaBar `.dmg` download and a copyable `brew install gotry-io/tap/quotabar`
   command. GitHub sign-in lives only in the site header.
2. `/my` is the signed-in dashboard: compact remaining-quota cards, account totals, cost coverage,
   Usage activity, model/agent breakdowns, Devices, and explicit Device deletion. Quota remaining
   has no "left"/"remaining" suffix; budget windows with an amount use `71% · $3.75`, percent-only
   windows use `71%`, and balance-only windows use **Balance** plus `$12.34`. Quota cards follow
   the same provider / account / remaining / meter / metadata order as QuotaBar Overview, in a
   denser web layout. The header shows the GitHub username; the name opens `/my`, and its menu
   contains only **Sign out**. Session cookies stay HttpOnly. SvelteKit renders the header from
   `WebDocumentPort.getViewer` on the first HTML byte. The dashboard still loads Usage from
   `GET /api/v2/account/summary` after paint. Unsigned visits to `/my` are a server redirect to
   `/`. A successful `/u/{slug}` page view consumes two `public-profile` limiter tokens (document
   existence plus the JSON payload); after 60 views / 10 minutes the HTML can remain 200 while the
   JSON returns 429. The shipped `/app`
   bookmark is a single redirect to `/my`. Every signed-in GitHub account is public at
   `/u/{github-username}`. The dashboard has no public-page visibility control.
3. `/u/{username}` is the public remaining-quota and usage view for that GitHub username. It never
   includes device ids, fingerprints, credentials, or private identifiers. Unknown usernames show
   a plain unavailable state.
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

Color never carries status alone. Every state also has a text label. The header theme control
toggles `light` and `dark`, stores the choice locally, and otherwise follows
`prefers-color-scheme`. Do not add a third visible “system” control.

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

The hero also presents the live GitHub Releases `.dmg` and the Homebrew tap command. Do not present
unavailable downloads or documentation as active destinations.

## Account dashboard

The dashboard leads with input tokens, output tokens, and API-equivalent cost. Cost always shows its
coverage/basis; unavailable cost renders as an em dash plus “Unpriced”, and partial cost uses a lower
bound marker. It reads all retained Account Usage by default. User-facing dates, numbers, units, and
plan names use the English presentation shared with QuotaBar rather than the browser locale.
Usage activity is a compact day grid whose cells use token volume for highlight levels, including a
distinct today outline. The dashboard does not repeat the GitHub username in the page heading.

Device cards show display name, platform, lifecycle status, and last-seen time. Deletion copy must
say that both the Device and its Quota/Usage data are removed. Agent Usage uses a semantic table with
real column headers. Empty, loading, unauthenticated, recent-auth-required, and service-error states
use plain explanatory text and one next action.

## Device authorization

`/activate` is a single-task form. It explains that approval issues Account-read and current-Device
upload sessions without sharing provider credentials. The code input supports one-time-code
autofill. Approve is primary; Deny is secondary. Success tells the user to return to the requesting
Quota client.

## Responsive behavior

- At 840 px, two-column hero and architecture layouts become one column.
- At 620 px, the page gutter reduces, navigation hides nonessential links, actions become full
  width where useful, summary grids stack, and data tables remain horizontally scrollable. The
  appearance toggle and account session control stay visible.
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
