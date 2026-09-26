# ADR 0064: Analysis surfaces lead with model usage; glance surfaces lead with quota

- Status: Accepted
- Date: 2026-09-26
- Updates [ADR 0051](0051-the-panel-glances-and-the-windows-explain.md), whose website kept
  cross-device Usage behind a quota-first overview
- Follows [ADR 0059](0059-the-leaderboard-is-retired.md)

## Context

Every Quota surface opened with the same question, "Can I keep working?", because
[`docs/design.md`](../design.md) principle 1 said so. That is right for the menu-bar panel, a
widget, and the iPhone's first tab: they are read in a second, between prompts. It is wrong for
the website's `/my`, the iPhone's Usage tab, and the QuotaBar main window's Usage page, which are
opened to understand a period. There the answer came as a wall of equal cards — subscription
groups, then a Today strip, then three to five stat tiles — and the model breakdown, the one thing
only Quota can show across agents, sat under them as a table.

A survey of about forty products on 2026-09-26 (AI-coding quota and usage tools, model-usage
analytics dashboards, and personal-data products people keep open) found two camps. Quota tools
(CodexBar, the Claude and Codex usage pages) show only what is left. Usage tools (ccusage,
tokscale, WakaTime) show only what was used. Neither links the two, and both default to card grids
or long tables. The products that read clearly lead with one chart and one grouped list whose rows
are the legend (Plausible, Braintrust, OpenRouter's app page), colour models by vendor rather than
by rank, and keep cache as a band inside the token total (Datadog). The retention devices that
reward burning tokens — leaderboards, percentiles, spend tiers, usage streaks — contradict
[ADR 0059](0059-the-leaderboard-is-retired.md), which retired the board for exactly that reason.

Quota already holds both halves: remaining quota per window and Usage per model, agent, and hour.

## Decision

**Glance surfaces answer quota first. Analysis surfaces open with the reader's model usage and
keep quota in view.**

1. **Surfaces divide by platform role.** The QuotaBar panel, the iPhone Quota tab, and widgets
   stay glances: remaining, reset, risk, in that order. The website `/my`, the iPhone Usage tab,
   and the QuotaBar main window's Usage page are analysis surfaces: a sentence about the reader's
   own model usage with its numbers, one stacked chart by model, and a model ledger. The website
   keeps quota on screen with a quota band under its header on every signed-in page, and gives
   quota its own page. Each platform keeps its own information architecture; they share
   components and meaning, not layouts.
2. **A model's colour comes from its inference provider and its rank inside that provider.** Each
   provider has a hue family of four shades; the model's shade is its rank by tokens inside that
   provider over the Account's `all` period (the summary's 730 days), and rank 5 and below share
   one neutral `other`. Ranking over all history rather than the period on screen keeps a model's
   colour when the period, page, or device changes; it moves only when long-run use does. One pure
   function per platform makes the assignment once, and every chart on that surface uses it.
   Colour is never assigned by rank across providers, and no model is ever mint.
3. **Mint belongs to Quota.** The brand colour marks the Quota logo, cached input, healthy
   remaining, focus, and switches. In a token mix, cache read is brand, cache write is brand light,
   fresh input is neutral, and output is ink. The Apple daily chart drops emerald for fresh input
   in the same change. Amber and red mean risk and nothing else.
4. **A weekly recap is a page, not a notification, this cycle.** The website has `/my/recap`,
   derived from the period read it already makes. The Monday notification comes later.
5. **Not built.** Plan value (no plan price catalog exists), personal records that depend on quota
   history, leaderboards, percentiles, and usage streaks, and a command palette (optional, last).
   A record may celebrate efficiency — a cache rate, a cost per message — never volume.
6. **Web charts are hand-drawn SVG.** No chart library is added to the website. Apple uses Swift
   Charts marks and the existing `Canvas` drawings.

## Consequences

- `docs/design.md` principle 1 splits into the glance rule and the analysis rule, and its component
  contracts gain the sentence header, quota band, tightest-window gauge, even-pace tick, next
  resets, model river, model ledger, token mix, agents → models flow, and weekly recap poster.
  `apps/web/DESIGN.md` is rewritten for the new web routes.
- `packages/design-tokens` carries `color.model.<provider>.<1–4>` and `color.model.other`, and the
  chart roles above including `chart.cache_write`. A surface that needs a model colour reads those
  tokens; none keeps its own palette.
- The website's `/my` is Home (usage), with Models, Quota, and Recap beside it; Devices, Settings,
  and the public page move to the account menu. The QuotaBar panel and the iPhone Quota tab keep
  their order and take the same meters, pace tick, and next-resets components.
- The collection request the website's Overview made on load
  ([ADR 0063](0063-collection-follows-demand-and-activity.md)) is made by the Quota page, whose
  meta line carries **Asking your Mac…**; the rule for when to ask is unchanged.
- Wide model-by-day series come from Relay's period read (`series=model`), added as an optional
  field under [ADR 0023](0023-strict-writes-tolerant-reads.md) rather than a protocol version.
- Rank-by-provider colours can change when a provider's long-run top four changes. That is rarer
  than a period switch, and the alternative — colour by rank on screen — changes a model's colour
  every time the period does.

## What was given up

The quota-first overview as the website's front page, and the Today strip and stat-tile rows as the
default headline. A reader who only wants what is left now reads it in the quota band or on the
Quota page, one click away, rather than as the first thing on `/my`.
