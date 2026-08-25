import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import type { UsageBreakdown, UsageCostOutcome } from "@gotry-io/quota-protocol";
import {
  ACTIVITY_TOOLTIP_MARGIN,
  ACTIVITY_WEEKDAY_LABELS,
  buildUsageActivityModel,
  formatActivityTooltip,
  placeActivityTooltip,
  usageDateBreakdowns,
  usageDayCoverageLabel,
  usageDayNotices,
} from "../src/lib/usage-activity.ts";

function emptyTotals(
  overrides: { input_tokens?: number; output_tokens?: number; requests?: number } = {},
) {
  return {
    input_tokens: 0,
    cache_read_tokens: 0,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 0,
    cache_write_inferred_tokens: 0,
    output_tokens: 0,
    reasoning_tokens: 0,
    requests: 0,
    web_search_requests: 0,
    web_fetch_requests: 0,
    source_cost_microusd: null,
    source_cost_covered_requests: 0,
    ...overrides,
  };
}

function cost(overrides: Partial<UsageCostOutcome> = {}): UsageCostOutcome {
  return {
    mode: "calculate",
    basis: "calculated",
    status: "complete",
    amount_microusd: "1230000",
    catalog_revision: null,
    calculated_rows: 1,
    reported_rows: 0,
    unpriced_rows: 0,
    assumptions: [],
    unpriced: [],
    ...overrides,
  };
}

function dateBreakdown(
  date: string,
  input: number,
  output: number,
  dayCost: UsageCostOutcome,
): UsageBreakdown {
  return {
    dimension: "usage_date",
    key: date,
    totals: emptyTotals({
      input_tokens: input,
      output_tokens: output,
      requests: 1,
    }),
    cost: dayCost,
  };
}

test("pads to Sunday-first weeks and keeps in-range days selectable", () => {
  const model = buildUsageActivityModel(
    [dateBreakdown("2026-01-15", 100, 20, cost())],
    { from: "2026-01-15", to: "2026-01-16" },
    "2026-01-16",
  );

  assert.equal(model.days[0]?.date, "2026-01-11");
  assert.equal(new Date(`${model.days[0]?.date}T00:00:00Z`).getUTCDay(), 0);
  assert.equal(model.days.at(-1)?.date, "2026-01-17");
  assert.equal(new Date(`${model.days.at(-1)?.date}T00:00:00Z`).getUTCDay(), 6);
  assert.equal(model.days.length % 7, 0);
  assert.equal(model.weeks[0]?.[0]?.date, "2026-01-11");
  assert.equal(model.days.find((day) => day.date === "2026-01-14")?.outside, true);
  assert.equal(model.days.find((day) => day.date === "2026-01-15")?.outside, false);
  assert.equal(model.days.find((day) => day.date === "2026-01-16")?.today, true);
  assert.deepEqual([...ACTIVITY_WEEKDAY_LABELS], ["", "Mon", "", "Wed", "", "Fri", ""]);
});

test("keeps per-day totals and cost and ignores non-date breakdowns", () => {
  const priced = cost({ amount_microusd: "2500000", status: "complete" });
  const model = buildUsageActivityModel(
    [
      {
        dimension: "agent",
        key: "codex",
        totals: emptyTotals({ input_tokens: 9_999, output_tokens: 9_999, requests: 9 }),
        cost: priced,
      },
      dateBreakdown("2026-03-02", 100, 40, priced),
      dateBreakdown("2026-03-02", 50, 10, cost({ amount_microusd: "400000", status: "partial" })),
    ],
    { from: "2026-03-02", to: "2026-03-02" },
    "2026-03-02",
  );

  const day = model.days.find((item) => item.date === "2026-03-02");
  assert.equal(day?.tokens, 200);
  assert.equal(day?.input_tokens, 150);
  assert.equal(day?.output_tokens, 50);
  assert.equal(day?.requests, 2);
  assert.equal(day?.cost?.status, "partial");
  assert.equal(day?.cost?.amount_microusd, "400000");
  assert.deepEqual(
    usageDateBreakdowns([
      {
        dimension: "agent",
        key: "codex",
        totals: emptyTotals({ requests: 1 }),
        cost: priced,
      },
      dateBreakdown("2026-03-02", 1, 1, priced),
    ]).map((item) => item.key),
    ["2026-03-02"],
  );
});

test("places month labels on week columns and drops overlapping neighbors", () => {
  const wide = buildUsageActivityModel([], { from: "2026-01-01", to: "2026-03-15" }, "2026-03-15");
  assert.deepEqual(
    wide.monthLabels.map((label) => ({ weekIndex: label.weekIndex, label: label.label })),
    [
      { weekIndex: 0, label: "Jan" },
      { weekIndex: 5, label: "Feb" },
      { weekIndex: 9, label: "Mar" },
    ],
  );
  assert.equal(wide.monthLabels[0]?.span, 5);
  assert.equal(wide.monthLabels[1]?.span, 4);

  const tight = buildUsageActivityModel([], { from: "2026-01-31", to: "2026-02-02" }, "2026-02-02");
  assert.equal(tight.weeks.length, 2);
  assert.deepEqual(
    tight.monthLabels.map((label) => label.label),
    ["Jan"],
  );
  assert.equal(tight.monthLabels[0]?.weekIndex, 0);
  assert.equal(tight.monthLabels[0]?.span, 2);
});

test("anchors a mid-week month on the Sunday-first week that contains its first visible day", () => {
  const june = buildUsageActivityModel([], { from: "2026-05-01", to: "2026-06-15" }, "2026-06-15");
  assert.equal(new Date("2026-06-01T00:00:00Z").getUTCDay(), 1);
  const juneWeek = june.weeks.findIndex((week) => week.some((day) => day.date === "2026-06-01"));
  assert.equal(juneWeek, 5);
  assert.equal(june.weeks[juneWeek]?.[0]?.date, "2026-05-31");
  assert.deepEqual(
    june.monthLabels.map((label) => ({ weekIndex: label.weekIndex, label: label.label })),
    [
      { weekIndex: 0, label: "May" },
      { weekIndex: 5, label: "Jun" },
    ],
  );

  const july = buildUsageActivityModel([], { from: "2026-06-15", to: "2026-07-10" }, "2026-07-10");
  assert.equal(new Date("2026-07-01T00:00:00Z").getUTCDay(), 3);
  const julyWeek = july.weeks.findIndex((week) => week.some((day) => day.date === "2026-07-01"));
  const julyWeekStart = july.weeks[julyWeek]?.[0]?.date;
  assert.ok(julyWeek >= 0);
  assert.ok(julyWeekStart);
  assert.equal(julyWeekStart < "2026-07-01", true);
  assert.equal(july.monthLabels.find((label) => label.label === "Jul")?.weekIndex, julyWeek);
  assert.notEqual(july.monthLabels.find((label) => label.label === "Jul")?.weekIndex, julyWeek + 1);
});

test("keeps an in-page tooltip inside the viewport without overflowing", () => {
  const above = placeActivityTooltip({
    cell: { left: 200, top: 120, right: 214, bottom: 134 },
    viewport: { width: 800, height: 600 },
    tooltip: { width: 180, height: 48 },
  });
  assert.equal(above.placement, "above");
  assert.equal(above.left, 200 + 7 - 90);
  assert.equal(above.top, 120 - 8 - 48);

  const leftEdge = placeActivityTooltip({
    cell: { left: 2, top: 80, right: 16, bottom: 94 },
    viewport: { width: 400, height: 400 },
    tooltip: { width: 180, height: 40 },
  });
  assert.equal(leftEdge.left, ACTIVITY_TOOLTIP_MARGIN);
  assert.ok(leftEdge.left + 180 <= 400 - ACTIVITY_TOOLTIP_MARGIN);

  const rightEdge = placeActivityTooltip({
    cell: { left: 380, top: 80, right: 394, bottom: 94 },
    viewport: { width: 400, height: 400 },
    tooltip: { width: 180, height: 40 },
  });
  assert.equal(rightEdge.left, 400 - ACTIVITY_TOOLTIP_MARGIN - 180);
  assert.ok(rightEdge.left >= ACTIVITY_TOOLTIP_MARGIN);

  const below = placeActivityTooltip({
    cell: { left: 40, top: 10, right: 54, bottom: 24 },
    viewport: { width: 400, height: 400 },
    tooltip: { width: 120, height: 40 },
  });
  assert.equal(below.placement, "below");
  assert.equal(below.top, 24 + 8);
});

test("activity markup uses a day-button group and a custom tooltip, not a native title", () => {
  const source = readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), "../src/lib/components/UsageActivity.svelte"),
    "utf8",
  );
  assert.match(source, /role="group"/);
  assert.doesNotMatch(source, /role="grid"/);
  assert.match(source, /class="usage-activity-tooltip"/);
  assert.match(source, /aria-label=\{day\.tooltip\}/);
  assert.doesNotMatch(source, /\btitle=/);
  assert.match(source, /if \(found\) showTooltip/);
  assert.match(source, /else hideTooltip\(\)/);
});

test("tooltip states tokens, estimated cost, and unpriced or partial meaning", () => {
  assert.equal(
    formatActivityTooltip({ date: "2026-08-14", tokens: 12_400, cost: null }),
    "August 14, 2026 · 12.4K tokens · — Unpriced",
  );
  assert.equal(
    formatActivityTooltip({
      date: "2026-08-14",
      tokens: 100,
      cost: { status: "unavailable", amount_microusd: null, basis: "none" },
    }),
    "August 14, 2026 · 100 tokens · — Unpriced",
  );
  assert.equal(
    formatActivityTooltip({
      date: "2026-08-14",
      tokens: 100,
      cost: { status: "complete", amount_microusd: "1230000", basis: "calculated" },
    }),
    "August 14, 2026 · 100 tokens · $1.23 API-equivalent · estimated",
  );
  assert.equal(
    formatActivityTooltip({
      date: "2026-08-14",
      tokens: 100,
      cost: { status: "partial", amount_microusd: "1230000", basis: "calculated" },
    }),
    "August 14, 2026 · 100 tokens · ≥ $1.23 API-equivalent · priced subset only",
  );
});

test("day notices describe empty, truncated, and partial coverage honestly", () => {
  assert.deepEqual(
    usageDayNotices({
      totals: { input_tokens: 0, output_tokens: 0, requests: 0 },
      breakdowns: [],
    }),
    ["No Usage has been synced for this day."],
  );
  assert.deepEqual(
    usageDayNotices({
      totals: { input_tokens: 10, output_tokens: 2, requests: 1 },
      breakdowns: [{}],
      breakdowns_truncated: true,
    }),
    ["Some agent or model rows were omitted."],
  );
  assert.equal(usageDayCoverageLabel("none"), "No coverage reported");
  assert.equal(usageDayCoverageLabel("complete"), "Complete");
  assert.equal(usageDayCoverageLabel("partial"), "Partial");
});
