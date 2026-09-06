import { expect, it } from "vitest";
import {
  cacheHitLabel,
  cacheSavedLabel,
  dailyMaximum,
  dailySpan,
  shareLabel,
  usageDailyRows,
  usageModelShares,
  usageProviderShares,
} from "./usage-metrics.ts";

function totals(input: number, cacheRead: number, output = 0) {
  return {
    total_tokens: input + output,
    input_tokens: input,
    output_tokens: output,
    cache_read_input_tokens: cacheRead,
    cache_write_input_tokens: 0,
    reasoning_tokens: 0,
    messages: 1,
  };
}

function cost(amount: string | null, status = "complete") {
  return { amount_microusd: amount, status, basis: "calculated" };
}

it("states the cache hit rate as whole percent, and no rate without input", () => {
  expect(cacheHitLabel(totals(1_000, 940))).toBe("94%");
  expect(cacheHitLabel(totals(0, 0))).toBe(null);
});

it("names a saving as a saving, and says nothing when nothing could be priced", () => {
  expect(cacheSavedLabel({ amount_microusd: "1500000", status: "complete" })).toBe("saved $1.50");
  expect(cacheSavedLabel({ amount_microusd: "1500000", status: "partial" })).toBe("saved ≥ $1.50");
  expect(cacheSavedLabel({ amount_microusd: null, status: "unavailable" })).toBe(null);
});

it("has no share of a whole of zero", () => {
  expect(shareLabel(0, 0)).toBe(null);
  expect(shareLabel(1, 3)).toBe("33%");
});

it("fills in the days a period covers that reported nothing", () => {
  const days = [
    { date: "2026-09-04", totals: totals(100, 50, 20), cost: cost("7"), partial: true },
  ];
  const rows = usageDailyRows(days, "7d", "2026-09-05");

  expect(rows.map((row) => row.date)).toStrictEqual([
    "2026-08-30",
    "2026-08-31",
    "2026-09-01",
    "2026-09-02",
    "2026-09-03",
    "2026-09-04",
    "2026-09-05",
  ]);
  const reported = rows[5];
  expect(reported?.partial).toBe(true);
  // The three stacked shares add up to the day's total, so the bar is the total it names.
  expect(reported?.segments).toStrictEqual({ freshInput: 50, cachedInput: 50, output: 20 });
  expect(rows[6]?.totals.total_tokens).toBe(0);
  expect(rows[6]?.cost.amount_microusd).toBe(null);
  expect(dailyMaximum(rows, "tokens")).toBe(120);
  expect(dailyMaximum(rows, "cost")).toBe(7);
});

it("has no daily table for the period the activity graph already answers", () => {
  expect(dailySpan("all")).toBe(null);
  expect(usageDailyRows([], "all", "2026-09-05")).toStrictEqual([]);
});

it("ranks model and provider shares by tokens, largest first", () => {
  const agents = [
    {
      agent: "codex",
      providers: [
        {
          provider: "openai",
          models: [
            { model: "gpt-5", totals: totals(100, 0, 100), cost: cost("1") },
            { model: "gpt-5-mini", totals: totals(10, 0, 10), cost: cost("1") },
          ],
        },
      ],
    },
    {
      agent: "claude_code",
      providers: [
        {
          provider: "anthropic",
          models: [{ model: "claude-opus", totals: totals(400, 0, 100), cost: cost("1") }],
        },
      ],
    },
  ];

  expect(usageModelShares(agents).map((model) => model.model)).toStrictEqual([
    "claude-opus",
    "gpt-5",
    "gpt-5-mini",
  ]);
  expect(usageProviderShares(agents)).toStrictEqual([
    { provider: "anthropic", tokens: 500 },
    { provider: "openai", tokens: 220 },
  ]);
});
