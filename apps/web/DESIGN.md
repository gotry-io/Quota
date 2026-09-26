# Quota Web Design

Quota Web platform deltas only. The shared language — principles, colour roles, components, copy —
is [`docs/design.md`](../../docs/design.md); the website is an analysis surface there
([ADR 0064](../../docs/decisions/0064-analysis-surfaces-lead-with-model-usage.md)). Data ownership
is [`docs/architecture.md`](../../docs/architecture.md); authentication, CSRF, and deletion safety
are [`docs/security.md`](../../docs/security.md).

## Character

Editorial, quiet, precise: a useful open-source tool, not a hosting console or a SaaS dashboard.
Black type, white space, hairline rules. No gradients, drop shadows, glass, fake browser chrome,
bordered data cards, or ornamental charts. Charts are hand-drawn SVG; the site adds no chart
library. Light and dark follow the system until the footer control chooses one.

Copy follows [Shared product vocabulary](../../docs/design.md#shared-product-vocabulary);
`src/lib/format.ts` answers the freshness, reset, remaining, and pace fixtures. Provider and agent
names come from the catalog and `agentDisplayName`; the site keeps no name table. Dates, numbers,
and units use the English presentation QuotaBar uses, not the browser locale.

## Layout

- **One width.** Header, quota band, main, and footer share one content column: 1080 px plus a
  24 px gutter, 16 px at 768 px and below. No page is wider or narrower.
- **Page header.** Every page opens the same way: an eyebrow (page name, then the period or a
  breadcrumb), one `h1` sentence whose numbers are `<b>` in ink and the rest in body colour,
  controls aligned to the right and bottom (below 768 px they move under the sentence), then one
  meta line. Loading, empty, and error states keep the header and say so in the sentence.
- **Sections.** A hairline on top, a heading row (`h2` left, an optional note or link right), then
  the body. Wide pages may pair two sections, or a main column with a 300 px aside; both stack
  below 960 px.
- **Controls.** Pills are 32 px high (40 px at 768 px and below); segmented controls, tags, and
  switches as in the prototype. Primary is ink; brand fills only switches that are on.

## Navigation

Outside `/my` the header is the Quota mark and name, **Product**, **Download**, **Support**,
**GitHub ↗**, and **Sign in**. Signed in and under `/my`, `<nav aria-label="Account">` holds
**Home** (`/my`), **Models**, **Quota**, and **Recap** with `aria-current="page"`; it scrolls
sideways rather than wrapping. The account menu (first-letter mark) holds the signed-in label,
**Devices**, **Settings**, **Public page**, and **Sign out**. The header renders from
`WebDocumentPort.getViewer` on the first HTML byte; session cookies stay HttpOnly.

The footer: `© {year} GoTry IO · MIT`, Download, Support, Privacy, Terms, GitHub, Account, and one
appearance menu — **System** (default; no `data-theme`, follows `color-scheme` live), **Light**,
**Dark** (written to `localStorage` as `quota-theme`; System removes it).

## Signed-in data

`/my` is a signed-in shell that carries no Account data in its HTML. One client store holds the
summary (`GET /api/v6/account/summary` with the browser's IANA zone), activity keyed by `from|to`,
period reads keyed by `from|to|timezone|breakdown|series`, and day detail. Fresh reads are reused
for 60 seconds and revalidated in the background; account navigations re-run the summary read
without a skeleton over cached data; a matching `If-None-Match` reuses the last-good body.
Unsigned visits to `/my…` redirect to `/sign-in?return_to=<path>`; the shipped `/app` bookmark
redirects to `/my`. Every `/my` route is `noindex, nofollow`.

**Periods.** The control shows **Today**, **7D**, **30D**, and **90D** as segments (accessible
names are the full period names) and puts **This week**, **This month**, **All**, **Custom
range…**, **Export CSV**, and **Export JSON** under **More**; **Last 30 days** is the default.
The website adds **Last 90 days** to the shared periods because its period read answers any range
up to a year. **Previous period** and **Next period** sit beside the dates for Today, This week,
and This month, and Next is disabled on the current unit; Custom is two native date inputs
bounded by the activity range and **Apply**. The URL is
`?period=day|week|month|7d|30d|90d|all|custom` plus `&offset=` or `&from=&to=`, so a refresh keeps
it. Every selection but All reads `GET /api/v6/account/usage/period` with inclusive local dates,
this browser's zone, `breakdown=1`, and `series=model`; a single day's chart reads the seven days
ending on it. All is the summary's 730 UTC-day window, which has no series, so its chart asks for a
shorter period. The comparison is a second read of the equal range before it with the tree and no
series (the same days of the previous unit while a day, week, or month is still running; none
for All or Custom). Incomplete hours print **some hours incomplete**; a range retention cut
prints **some of this range is no longer kept**. Export writes the loaded period body and is off
for All ([ADR 0056](../../docs/decisions/0056-a-period-export-is-the-period-on-screen.md)).

**Quota band.** Under the header on every `/my` page, as specified in
[Components](../../docs/design.md#components), from the summary already loaded.

**Collection request.** Only the Quota page asks the Macs to collect: on load and when its tab
becomes visible again. It re-reads the summary every 30 seconds for three minutes and stops
when answered, hidden, or left; its meta line says **Asking your Mac…** (**Asking your Macs…**) meanwhile, then
`Latest quota updated <age> · <n> devices reporting` with **Refresh**. A refusal or timeout says
nothing ([ADR 0063](../../docs/decisions/0063-collection-follows-demand-and-activity.md)).

**Failure.** A failed read keeps what loaded and shows one notice with at most one action: **Your
session ended. Sign in again.** (401), **Sign in again to confirm this change.** or **You don't
have permission to do that.** (403), or **Quota couldn't load this.** with **Retry**. Loading uses
a skeleton with `aria-busy`. A new Account with no Mac sees the setup block: install QuotaBar, sign
in to Quota with the same method, connect a provider, **Download for macOS**.

## Routes

**`/my` — Home.** Sentence header: tokens and models for the period and the top model's share;
period controls with Export under More; meta line with API-equivalent cost, share of input from
cache, active days, and the token change against the previous period. Then: metric tabs (Tokens,
API-equivalent cost, Messages — each showing its total) over the model river with Amount / Share,
and the model ledger under it (six rows, then **N more models**). Messages are not split by model
per day, so that tab draws one neutral stream and says so, and Share is off. The river is one tab
stop: arrow keys, Home, and End move a crosshair whose reading is its spoken value; hovering or
focusing a ledger row fades every other band. Cost states its basis under the tabs (`Priced N of M
rows`, or **Cost covers every row** / **Cost skips N rows this catalog can't price**). Then **What
stood out** (up to four sentences from the reader's numbers: a model that arrived or the top
model's share and its move, cache reads and what they saved, a window under 40 %, the busiest
hours from the period's rhythm read); **Where the tokens went** (token mix) beside **Your year**
(activity grid); **Agents → models** (top eight models; a grouped list below 640 px), then records:
active days in the year, best cache day, models tried, lowest cost per message. Choosing a day in
the grid opens an inline panel, not a modal, and writes `?day=YYYY-MM-DD`: the day's tokens,
input/output, messages, cost and basis, incomplete hours, and its models as a ledger from
`GET /api/v6/account/usage/activity?from=D&to=D&detail=agents` (**No Usage on this day.** when
empty). Close drops the query and returns focus to the day. `/my/usage`, the shipped address,
redirects to `/my` with its query.

**`/my/models`.** Sentence header with the model count and either the model that arrived inside
the period or the two largest shares; period controls. Tokens / API-equivalent cost tabs over the
share river, then **Every model** — the full ledger with messages and cost per message — and, for
the selected model (`?model=`, the largest by default), its daily bars (for the eight models the
series names), tokens, cost, cost per message, cache share, the agents that sent to it, and aside
**In your quota**: the estimated share it used of the tightest window a day or longer of a
subscription its agents spend ("Estimated from this Account's hourly Usage inside the window"),
or a line that no such window is reported.

**`/my/quota`.** Sentence header naming the tightest window and whether anything else may run out
before reset; **List** / **Table** control; the collection status line with **Refresh**. Then the
tightest-window gauge (104 px, with its reset, pace line, and — for a window a day or longer — the
model that used most of it) with **Next resets** beside it, then **Subscriptions**: one row per
subscription — mark, provider name, masked account, plan tag, up to three windows (title,
remaining, meter with even-pace tick, reset, **may run out early** when pace says so), and the foot
`Studio Mac · 1m ago` or the status word and last reading. Table lists one row per window with its
pace. A 6 px dot in `--quota-warning` (minor) or `--quota-critical` (major or worse) beside the
provider name carries the official status description, from `GET /api/v2/providers/status`; none
for `none` or `unknown`. No Mac shows the setup block.

**`/my/subscriptions/<sel>`.** Eyebrow **Quota / \<provider\>**, sentence `<provider> · <plan>`,
**← Quota**, meta with the masked account and freshness; a reading that is not current says so
in a notice. **Windows**: remaining, meter with the even-pace tick, the pace line drawn from the
Account's quota history (`GET /api/v6/account/quota-history`, only while the history switch is on
and only for a global subscription), reset and pace copy; a passed refill prints no Resets line.
For the tightest window a day or longer, **What used this window**: a model split of its agents'
Usage since the window opened, labelled an estimate. **Expiring credits** lists a count window's
expiries in the shared expiry copy. Aside: **Readings** from `sources[]`, newest first, the
Device name (or **Device**), its primary remaining figure and freshness, the selected one tagged
**Reporting**; **Source** (read by QuotaBar, last reading, provider status). A selector with no
match reads **This subscription is no longer reported.** No device id, fingerprint, or
subscription key is printed.

**`/my/recap`.** Eyebrow **Recap · \<dates\>** for the last full week, Monday to Sunday;
sentence "Your week, in five numbers. Private until you copy one." Posters: volume (and its
change on the week before), model of the week (with that week's share river), cache efficiency
(and the best cache day), rhythm (busiest hour, and the longest quiet stretch), headroom now (the
tightest window and its reset). A poster whose numbers are missing is left out. **Copy as image**
draws the poster as a 1200×630 canvas and puts the PNG on the clipboard; nothing leaves the
browser. Then one line that nothing ranks the reader.

**`/my/devices`.** Sentence with how many devices report and the one that stopped. One table at
every width (scrolls sideways when narrow), newest contact first: name, **Active** / **Idle** /
**Not reporting** with a status dot and the word, last contact, platform (macOS or a generic
device), and **Delete…**, which confirms inline — "Removes it and its Quota and Usage data",
**Cancel**, **Delete** — never `window.confirm`. A sleeping Mac is Idle, not broken; no raw ids.

**`/my/settings`.** Sentence "Everything here follows your Account on every device." Two-column
groups (title and one sentence left, rows right; one column below 960 px):
- **Sign-in methods** — Apple, GitHub, Email. Bound: label and **Unlink** (ten-minute freshness,
  as Delete Account); the last one disabled with **Keep at least one way to sign in**. Unbound
  Apple or GitHub: **Link** to `/api/auth/<provider>/start?intent=link&return_to=/my/settings`;
  Email: **Link**, an inline `POST /api/auth/email/start` with `intent: "link"`, then **Check your
  email**. `?linked=taken` shows **That account is already linked to another Quota account.**
  once and drops the query.
- **Monthly budget** — amount, **Tell me at 80% and 100%**, and this month's meter against Account
  spend; the document is `GET`/`PUT /api/v2/account/settings`
  ([ADR 0061](../../docs/decisions/0061-alert-policy-and-the-budget-follow-the-account.md)). This
  browser keeps only the crossings it already showed, as one `role="status"` line with **Got it**.
- **Notifications** and **Privacy** — what that document holds and the web may write; delivery
  belongs to QuotaBar and Quota for iPhone, and the website sends nothing.
- **Public page** — handle (`quota.gotry.io/u/` prefix), **Publish this page**, **Show which
  models**, **Show API-equivalent cost**, one **Save**, and once published **Open page** and
  **Copy link**. A refused handle is named before the request; a held one reads **That handle is
  already taken.** Switching the page off keeps the handle.
- **Account** — display label and **Delete Account…**; `?delete=account` focuses that heading.

## Public pages

**`/`.** Left-aligned hero: "Every model your agents use, and what's left on every plan.", one
sentence that QuotaBar reads the providers on the Mac and credentials and prompts never leave it,
**Download for macOS** and **Sign in**, and a line with provider and agent counts and `Free & open
source · MIT · macOS 14+`. Then real product screenshots (light and dark assets switched by
`data-theme`, `width` and `height` declared; a snap gallery below 768 px, each image ≥ 280 px);
**Why people keep it open**; **Providers & agents** from the catalog with marks; **What never
leaves your Mac** with **Privacy →**; **Install**: the `.dmg` and the Homebrew command
`brew install gotry-io/tap/quotabar` with **Copy** (announces Copied through `aria-live`).
iPhone status is `IOS_AVAILABILITY` in `src/lib/platforms.ts`; no store link until it has a `url`.

**`/sign-in`.** Every sign-in starts here, including QuotaBar's and the iPhone's. Methods left,
three short points right (nothing to set up, no provider passwords, linking never merges).
Signed out: **Continue with Apple** (Apple's own black-or-white button and mark), **Continue with
GitHub** (both to `/api/auth/<provider>/start?return_to=…`), and email with **Send sign-in link**,
which becomes **Check your email** with **Use another way**. Signed in: **Continue as \<label\>**
and **Use a different account**. `return_to` defaults to `/my`, and anything but a same-origin
path is a 400. `delete=account` in `return_to` makes it **Sign in again to delete your account**
with the methods shown, since Continue as does not refresh `authenticated_at`. `intent=link` makes
it **Link a sign-in method** — "Linking adds a way to sign in to the account you're already using;
it never merges two accounts." — defaulting to `/my/settings`. `noindex, nofollow`.

**`/download`.** Sentence with the version, macOS 14 or later on Apple silicon, and that it
updates itself (Sparkle); groups for the disk image, Homebrew, and iPhone (Coming soon).
**`/support`**, **`/privacy`**, **`/terms`** render `src/content/*.md` in the same header and
width; Privacy and Terms are marked Draft until reviewed. Notifications are explained at
`/support#notifications`. The error page keeps the header and offers **Go to Home** and **Quota
site**.

**`/u/<handle>`.** The one route that shows Account data without a session. Header: the mark and
**Get Quota** only. Sentence header with `@handle` and the published totals, **Share**; Last 30
days and All time from `GET /api/v6/public/<handle>/usage` (models and cost only when the owner
published them), a 365-day grid drawn from bands with no day detail, and one line that quota,
sign-ins, devices, plans, and prompts stay private and nothing is ranked. Share opens a dialog with
a 1200×630 card drawn on a canvas, **Save image**, **Copy link**, **Close**; no server image, so
the Twitter card is `summary`. Canonical URL and Open Graph from the same sentence
([ADR 0037](../../docs/decisions/0037-a-public-profile-shows-usage-not-quota.md)).

Signing in is the only account action public pages take; the Web UI has no Relay selection,
provider secret form, or server administration.

## Type

Roles are in [`docs/design.md`](../../docs/design.md#type). System fonts only, no webfont:
headings and sentence headers `ui-rounded` / `SF Pro Rounded` then the system stack, weight 500;
body the system sans. Sentence headers are 32 px (24 px at 768 px and below); section headings
19 px; tabular digits for figures. Monospace only where the literal text matters (model ids, the
Homebrew command, codes).

## Responsive

- **960 px:** paired sections, asides, the tightest-window block, sign-in columns, and settings
  groups become one column; insights one column; record grids two columns.
- **768 px:** gutter 16 px; the brand name hides beside the mark; header controls wrap under the
  sentence; hero 34 px; ledger hides vs previous, from cache, provider, and agent columns; pills 40 px.
- From 320 px up: no clipped action and no horizontal page scroll. Wide content (charts, tables,
  nav, band, activity grid) scrolls inside itself.

## Accessibility

Landmarks, one `h1` per page, ordered headings, semantic tables, labelled controls, native buttons,
a working skip link. Targets are at least 32 px on desktop and 40 px at 768 px and below. Focus is
a visible brand outline with an offset, never hover-only. Notices use `role="status"` or
`role="alert"`. Every chart has a text alternative and pairs colour with a label. Keyboard: the
activity grid is one tab stop (arrows by day and week, Home/End, Page Up/Down, Enter or Space
opens the day and writes `?day=`); the river and ledger share hover and focus. Honour
`prefers-reduced-motion`. WCAG AA for text and controls.

## Tokens

Roles in [`docs/design.md`](../../docs/design.md#colour), values in
[`tokens.json`](../../packages/design-tokens/tokens.json); `src/app.css` imports the generated
custom properties (`--model-<provider>-<n>`, `--chart-cache`, …). Never hand-copy a hex value.

## Acceptance

Check, tests, e2e smoke, and build; then every route at 1440 and 390 px in light and dark, by
keyboard, in loading, signed-out, empty, unpriced, recent-auth, and failure states. No credential,
raw Usage, prompt, path, or untrusted HTML reaches the DOM.
