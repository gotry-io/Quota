import { expect, it } from "vitest";
import {
  cacheHitLabel,
  cacheSavedLabel,
  costPricedLabel,
  dailyBarKind,
  dailyChartSummary,
  dailyMaximum,
  dailyTooltip,
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

it("names how many rows the catalog priced", () => {
  expect(
    costPricedLabel({
      status: "complete",
      calculated_rows: 12,
      reported_rows: 0,
      unpriced_rows: 0,
    }),
  ).toBe("Priced 12 of 12 rows");
  expect(
    costPricedLabel({
      status: "partial",
      calculated_rows: 9,
      reported_rows: 1,
      unpriced_rows: 2,
    }),
  ).toBe("Priced 10 of 12 rows");
  expect(
    costPricedLabel({
      status: "unavailable",
      calculated_rows: 0,
      reported_rows: 0,
      unpriced_rows: 4,
    }),
  ).toBe("Priced 0 of 4 rows");
  expect(costPricedLabel({ status: "complete" })).toBe("Cost covers every row");
  expect(costPricedLabel({ status: "partial", unpriced_rows: 3 })).toBe(
    "Cost skips 3 rows this catalog can't price",
  );
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

it("maps the period's local days and leaves gaps unfilled", () => {
  const days = [
    { date: "2026-09-04", totals: totals(100, 50, 20), cost: cost("7"), partial: true },
  ];
  const rows = usageDailyRows(days, { from: "2026-09-04", to: "2026-09-04" });

  expect(rows.map((row) => row.date)).toStrictEqual(["2026-09-04"]);
  expect(rows[0]?.recorded).toBe(true);
  expect(rows[0]?.partial).toBe(true);
  // The three stacked shares add up to the day's total, so the bar is the total it names.
  expect(rows[0]?.segments).toStrictEqual({ freshInput: 50, cachedInput: 50, output: 20 });
  expect(dailyMaximum(rows, "tokens")).toBe(120);
  expect(dailyMaximum(rows, "cost")).toBe(7);
});

it("keeps a slot for a missing local date in the asked range", () => {
  const day = (date: string) => ({
    date,
    totals: totals(100, 50, 20),
    cost: cost("7"),
    partial: false,
  });
  const rows = usageDailyRows(
    [
      day("2026-09-01"),
      day("2026-09-02"),
      day("2026-09-03"),
      day("2026-09-05"),
      day("2026-09-06"),
      day("2026-09-07"),
    ],
    { from: "2026-09-01", to: "2026-09-07" },
  );

  expect(rows.map((row) => row.date)).toStrictEqual([
    "2026-09-01",
    "2026-09-02",
    "2026-09-03",
    "2026-09-04",
    "2026-09-05",
    "2026-09-06",
    "2026-09-07",
  ]);
  expect(rows.filter((row) => !row.recorded)).toHaveLength(1);
  const gap = rows[3];
  expect(gap?.date).toBe("2026-09-04");
  expect(gap?.recorded).toBe(false);
  expect(gap ? dailyBarKind(gap, "tokens") : null).toBe("empty");
  expect(gap ? dailyTooltip(gap, "tokens") : null).toBe("2026-09-04 · no usage recorded");
  expect(gap ? dailyTooltip(gap, "cost") : "").not.toContain("$0");
  expect(gap ? dailyTooltip(gap, "cost") : "").not.toContain("0 tokens");
});

it("has no daily table when the period named no local days", () => {
  expect(usageDailyRows([], null)).toStrictEqual([]);
});

it("draws an empty day as a tick and an unpriced day as unpriced, not $0", () => {
  const rows = usageDailyRows(
    [
      {
        date: "2026-09-04",
        totals: totals(100, 50, 20),
        cost: cost("2500000"),
        partial: false,
      },
      {
        date: "2026-09-05",
        totals: totals(40, 0, 10),
        cost: cost(null, "unavailable"),
        partial: false,
      },
      {
        date: "2026-09-06",
        totals: totals(0, 0, 0),
        cost: cost(null, "unavailable"),
        partial: false,
      },
    ],
    { from: "2026-09-04", to: "2026-09-06" },
  );
  expect(dailyBarKind(rows[0]!, "tokens")).toBe("amount");
  expect(dailyBarKind(rows[1]!, "cost")).toBe("unpriced");
  expect(dailyBarKind(rows[2]!, "tokens")).toBe("empty");
  expect(dailyBarKind(rows[2]!, "cost")).toBe("empty");
  expect(dailyMaximum(rows, "cost")).toBe(2_500_000);
  expect(dailyTooltip(rows[1]!, "cost")).toBe("2026-09-05 · unpriced");
  expect(dailyTooltip(rows[2]!, "tokens")).toBe("2026-09-06 · 0 tokens");
  expect(dailyChartSummary(rows, "cost")).toContain("unpriced");
  expect(dailyChartSummary(rows, "cost")).not.toContain("$0");
  expect(dailyChartSummary(rows, "tokens")).toContain("tokens");
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
