# ADR 0051: The panel glances, and the windows explain

- Status: Proposed
- Date: 2026-09-16
- Follows [ADR 0035](0035-quota-pace-is-derived-from-the-reading.md),
  [ADR 0037](0037-a-public-profile-shows-usage-not-quota.md),
  [ADR 0039](0039-project-attribution-stays-local.md),
  [ADR 0042](0042-quota-history-is-local-samples.md), and
  [ADR 0045](0045-the-leaderboard-is-a-page-you-opt-into.md)

## Context

QuotaBar's menu-bar panel is 320×480 and currently stacks Overview, Settings, Usage, and every
preference page inside that one extra. The panel is the right size to glance at remaining quota. It
is the wrong size to manage an account, inspect 30 days of burn, or edit four Menu Bar choices as
separate pages.

[ADR 0042](0042-quota-history-is-local-samples.md) already keeps 30 days of this Mac's samples in
`cache.sqlite` and folds the running window onto Overview for the pace sparkline. Dashboard wants
the rest of that journal: every window's curve, today's cost per window, and Usage at width. Two
ways to hand it over were on the table. Plan A puts the folded 30-day history on every state push,
the way Overview already carries the current window. Plan B adds a read-only IPC operation
`quota_history { since }` and leaves the state push on the current-window slice.

The fold was measured the way a state push serialises it: `LocalQuotaHistory` restates each
snapshot, `overview` is encoded as compact JSON, and history appears on both the item snapshot and
the local source snapshot.

- **Synthetic Plan A fill** — 30 days × 12 catalog providers × three windows (`five_hour`,
  `weekly`, `monthly`) at the 300 s decimation: **311,076** rows fold to **12,569,056** bytes
  (12,274.5 KB). The `history` objects alone are 12,544,728 bytes. That is 61× the 200 KB budget,
  and 12× the 1 MiB IPC line limit, so it cannot travel on `get_state` at all.
- **This Mac's `cache.sqlite`** — copied read-only, never written: **3,244** rows (four providers,
  about nine days of real collection) fold to **194,142** bytes. Under the budget today, and not
  the 30-day twelve-provider grid the Dashboard has to survive.

The synthetic fill is the one that would refuse Plan A. It is pinned by
`thirty_day_history_in_state_exceeds_the_plan_a_budget` in `packages/service`.

## Decision

**QuotaBar has three surfaces.** The menu-bar panel is a glance: Overview and one provider's
detail, 320×480, nothing else. The Settings window is where every preference lives. The Dashboard
window is where this Mac's 30-day quota history, today's cost per window, and Usage are read at
width.

**The website keeps cross-device Usage, public profiles, and the leaderboard**
([ADR 0037](0037-a-public-profile-shows-usage-not-quota.md),
[ADR 0045](0045-the-leaderboard-is-a-page-you-opt-into.md)). Neither the website nor the Account
gains a history view; neither window gains an upload. Every number a window shows comes from
`cache.sqlite`, `identity.sqlite`, or the Account summary the panel already reads
([ADR 0039](0039-project-attribution-stays-local.md),
[ADR 0042](0042-quota-history-is-local-samples.md)).

**Opening a window sets the activation policy to regular**, so a Dock icon and ⌘Tab entry exist
while a window is open; closing the last one returns to accessory. QuotaBar stays `LSUIElement`.

**Menu Bar preferences are one form, not four pages.**

**Dashboard reads 30-day history through a dedicated read-only IPC operation, not on every
state push (plan B).** The operation is `quota_history { since }`. The state push keeps the
current-window slice Overview already draws. The samples still never leave this Mac.

## Consequences

- The panel stops being a Settings host. Usage, Agents, Notifications, Menu Bar, and Support move
  out of the 320×480 extra and into the windows. The widget deep links (`quotabar://` Overview and
  subscription) still land in the panel; a `quotabar://dashboard` link opens the Dashboard window.
- Only the Settings and Dashboard windows drive the activation policy. The browser-access grant
  window and Sparkle's update window keep the behaviour they have today.
- WP 7.6 implements `quota_history { since }`. Adding that operation is a private IPC change and
  ships atomically with QuotaBar; `quota` the public command and Relay are untouched.
- A later fold that actually fits in 200 KB would be a reason to revisit Plan A. Until a
  measurement says so, the 30-day journal is a read, not a push.
