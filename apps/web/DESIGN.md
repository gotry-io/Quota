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
- Prefer clear labels and real values over decoration.
- Do not use gradients, drop shadows, glass effects, fake browser chrome, or ornamental charts.
- Product names are Quota, QuotaBar, and QuotaRelay.

## Information architecture

The site has three surfaces:

1. `/` explains local collection, one GitHub-backed Account, Devices, and API-equivalent Usage cost.
2. `/my` shows the signed-in user's name, quota snapshots, account totals, cost coverage, Usage
   activity, model/agent breakdowns, Devices, and explicit Device deletion. Quota remaining has no
   "left"/"remaining" suffix; budget windows with an amount use `71% · $3.75`, percent-only windows
   use `71%`, and balance-only windows use **Balance** plus `$12.34`. Account actions live in
   the account menu, whose trigger is the signed-in GitHub username. The shipped `/app` bookmark
   is a single redirect to `/my`.
3. `/activate` approves or denies a released native-client device authorization code.

GitHub is the only sign-in action. There is no Relay selection, pairing group, owner capability,
provider-secret form, server administration, or self-hosted setup in the Web UI.

## Tokens

Tokens are defined in `src/styles.css` and must remain the source used by the implementation.

### Color

| Role | Value | Use |
| --- | --- | --- |
| Ink | `#000000` | Primary type and primary actions |
| Deep ink | `#090909` | Primary-action hover |
| Charcoal | `#525252` | Secondary labels and navigation |
| Body | `#737373` | Supporting prose |
| Muted | `#a3a3a3` | Tertiary metadata |
| Emerald | `#087456` | Brand and healthy/complete meaning |
| Mint | `#82ddb8` | Brand accent |
| Brand surface | `#f2f8f5` | Quiet highlighted regions |
| Canvas | `#ffffff` | Page and cards |
| Soft surface | `#fafafa` | Hover and low-contrast grouping |
| Dark surface | `#171717` | One bounded inverted section |
| Hairline | `#e5e5e5` | Dividers and card outlines |

Color never carries status alone. Every state also has a text label.

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

The hero headline is “Know what you have left.” Its primary action is GitHub sign-in and its
secondary action scrolls to the product explanation. The product preview may show representative
account Usage, but it must label the cost as API-equivalent and state that unknown prices remain
unpriced.

The explanation follows this order:

- local collection and what never uploads;
- one Account with Device visibility;
- defensible, effective-dated cost;
- the direct local agent logs → QuotaBar local service → Account data path;
- a final GitHub sign-in action.

Do not present unavailable downloads or documentation as active destinations.

## Account dashboard

The dashboard leads with input tokens, output tokens, and API-equivalent cost. Cost always shows its
coverage/basis; unavailable cost renders as an em dash plus “Unpriced”, and partial cost uses a lower
bound marker. It reads all retained Account Usage by default. User-facing dates, numbers, units, and
plan names use the English presentation shared with QuotaBar rather than the browser locale.

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
  width where useful, summary grids stack, and data tables remain horizontally scrollable.
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
  widths when browser tooling is available;
- navigate all controls with a keyboard;
- verify loading, signed-out, empty, partial/unpriced cost, recent-auth, and failure states;
- confirm no credential, raw Usage, prompt, path, or untrusted HTML reaches the DOM.
