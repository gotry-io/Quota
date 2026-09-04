import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import type { UsageActivityDay, UsageCostOutcome } from "@gotry-io/quota-protocol";
import {
  ACTIVITY_TOOLTIP_MARGIN,
  ACTIVITY_WEEKDAY_LABELS,
  activityRoverFromKey,
  buildUsageActivityModel,
  formatActivityDate,
  formatActivityTooltip,
  nextActivityDate,
  placeActivityTooltip,
  usageActivityDayFromQuery,
  usageActivityDayHref,
} from "../src/lib/usage-activity.ts";

function totals(input: number, output: number, messages = 1) {
  return {
    total_tokens: input + output,
    input_tokens: input,
    output_tokens: output,
    cache_read_input_tokens: 0,
    cache_write_input_tokens: 0,
    reasoning_tokens: 0,
    messages,
  };
}

function cost(overrides: Partial<UsageCostOutcome> = {}): UsageCostOutcome {
  return {
    mode: "auto",
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

function day(
  date: string,
  input: number,
  output: number,
  dayCost: UsageCostOutcome,
): UsageActivityDay {
  return { date, totals: totals(input, output), cost: dayCost, partial: false };
}

test("pads to Sunday-first weeks and keeps in-range days selectable", () => {
  const model = buildUsageActivityModel(
    [day("2026-01-15", 100, 20, cost())],
    { from: "2026-01-15", to: "2026-01-16" },
    "2026-01-16",
  );

  assert.equal(model.days[0]?.date, "2026-01-11");
  assert.equal(new Date(`${model.days[0]?.date}T00:00:00Z`).getUTCDay(), 0);
  assert.equal(model.days.at(-1)?.date, "2026-01-17");
  assert.equal(new Date(`${model.days.at(-1)?.date}T00:00:00Z`).getUTCDay(), 6);
  assert.equal(model.days.length % 7, 0);
  assert.equal(model.weeks[0]?.[0]?.date, "2026-01-11");
  assert.equal(model.days.find((item) => item.date === "2026-01-14")?.outside, true);
  assert.equal(model.days.find((item) => item.date === "2026-01-15")?.outside, false);
  assert.equal(model.days.find((item) => item.date === "2026-01-16")?.today, true);
  assert.deepEqual([...ACTIVITY_WEEKDAY_LABELS], ["", "Mon", "", "Wed", "", "Fri", ""]);
});

test("takes each day's totals, cost, and scan verdict as Relay folded them", () => {
  const model = buildUsageActivityModel(
    [
      {
        ...day("2026-03-02", 150, 50, cost({ amount_microusd: "400000", status: "partial" })),
        partial: true,
      },
      day("2026-03-03", 10, 10, cost()),
    ],
    { from: "2026-03-02", to: "2026-03-03" },
    "2026-03-03",
  );

  const first = model.days.find((item) => item.date === "2026-03-02");
  assert.equal(first?.tokens, 200);
  assert.equal(first?.input_tokens, 150);
  assert.equal(first?.output_tokens, 50);
  assert.equal(first?.requests, 1);
  assert.equal(first?.partial, true);
  assert.equal(first?.cost?.status, "partial");
  assert.equal(first?.cost?.amount_microusd, "400000");
  // The busiest day sets the top of the scale, so a quiet day is a lighter cell.
  assert.equal(first?.level, 4);
  assert.equal(model.days.find((item) => item.date === "2026-03-03")?.level, 1);
  assert.equal(model.days.find((item) => item.date === "2026-03-04")?.level, 0);
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

test("activity markup uses a roving day-button group and a custom tooltip, not a native title", () => {
  const source = readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), "../src/lib/components/UsageActivity.svelte"),
    "utf8",
  );
  assert.match(source, /role="group"/);
  assert.match(source, /aria-roledescription="grid"/);
  assert.doesNotMatch(source, /role="grid"/);
  assert.match(source, /tabindex=\{day\.date === roverDate \? 0 : -1\}/);
  assert.match(source, /aria-pressed=\{day\.date === selectedDate\}/);
  assert.match(source, /class="usage-activity-tooltip"/);
  assert.match(source, /aria-label=\{day\.tooltip\}/);
  assert.doesNotMatch(source, /\btitle=/);
  assert.match(source, /if \(found\) \{/);
  assert.match(source, /showTooltip\(found\.day, found\.button\)/);
  assert.match(source, /else hideTooltip\(\)/);
});

test("moves the active day by one day, one week, thirty days, and the week edges", () => {
  const model = buildUsageActivityModel([], { from: "2026-01-01", to: "2026-03-15" }, "2026-03-15");
  assert.equal(nextActivityDate(model.days, "2026-01-15", "next-day"), "2026-01-16");
  assert.equal(nextActivityDate(model.days, "2026-01-15", "previous-day"), "2026-01-14");
  assert.equal(nextActivityDate(model.days, "2026-01-15", "next-week"), "2026-01-22");
  assert.equal(nextActivityDate(model.days, "2026-01-15", "previous-week"), "2026-01-08");
  assert.equal(nextActivityDate(model.days, "2026-01-15", "page-forward"), "2026-02-14");
  assert.equal(nextActivityDate(model.days, "2026-01-15", "page-back"), "2026-01-01");
  assert.equal(nextActivityDate(model.days, "2026-01-01", "previous-day"), "2026-01-01");
  assert.equal(nextActivityDate(model.days, "2026-03-15", "next-day"), "2026-03-15");
  assert.equal(new Date("2026-01-15T00:00:00Z").getUTCDay(), 4);
  assert.equal(nextActivityDate(model.days, "2026-01-15", "row-start"), "2026-01-11");
  assert.equal(nextActivityDate(model.days, "2026-01-15", "row-end"), "2026-01-17");
});

test("maps grid keys onto rover actions", () => {
  assert.equal(activityRoverFromKey("ArrowLeft"), "previous-day");
  assert.equal(activityRoverFromKey("ArrowRight"), "next-day");
  assert.equal(activityRoverFromKey("ArrowUp"), "previous-week");
  assert.equal(activityRoverFromKey("ArrowDown"), "next-week");
  assert.equal(activityRoverFromKey("Home"), "row-start");
  assert.equal(activityRoverFromKey("End"), "row-end");
  assert.equal(activityRoverFromKey("PageUp"), "page-back");
  assert.equal(activityRoverFromKey("PageDown"), "page-forward");
  assert.equal(activityRoverFromKey("Enter"), "select");
  assert.equal(activityRoverFromKey(" "), "select");
  assert.equal(activityRoverFromKey("Tab"), null);
});

test("keeps ?day= in the URL when the date is in the activity range", () => {
  const range = { from: "2026-01-01", to: "2026-03-15" };
  assert.equal(usageActivityDayFromQuery("2026-01-15", range), "2026-01-15");
  assert.equal(usageActivityDayFromQuery("2025-12-31", range), null);
  assert.equal(usageActivityDayFromQuery("2026-02-31", range), null);
  assert.equal(usageActivityDayFromQuery("nope", range), null);
  assert.equal(usageActivityDayFromQuery(null, range), null);
  assert.equal(formatActivityDate("2026-01-15"), "January 15, 2026");
  assert.equal(
    usageActivityDayHref(new URL("https://quota.gotry.io/my/usage?period=today"), "2026-01-15"),
    "/my/usage?period=today&day=2026-01-15",
  );
  assert.equal(
    usageActivityDayHref(
      new URL("https://quota.gotry.io/my/usage?period=today&day=2026-01-15"),
      null,
    ),
    "/my/usage?period=today",
  );
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
