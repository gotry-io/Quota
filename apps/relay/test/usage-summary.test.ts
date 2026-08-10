import type { StoredUsageHourlyFact } from "@gotry-io/relay-core";
import { describe, expect, it } from "vitest";
import { PRICING_CATALOG } from "../src/pricing-catalog.ts";
import { buildUsageSummary } from "../src/usage-summary.ts";

describe("Usage summary", () => {
  it("folds a production-sized result into all six breakdowns without recomputing rows", () => {
    const rows = Array.from({ length: 796 }, usageRow);
    const summary = buildUsageSummary(
      { rows, coverage: [], truncated: false },
      { from: "2026-07-12", to: "2026-08-10" },
      "calculate",
      PRICING_CATALOG,
    );

    expect(summary.cost).toMatchObject({
      status: "complete",
      calculated_rows: rows.length,
      unpriced_rows: 0,
    });
    expect(summary.breakdowns).toHaveLength(293);
    for (const dimension of [
      "device",
      "agent",
      "model",
      "billing_channel",
      "usage_date",
      "bucket_start_utc",
    ] as const) {
      expect(
        summary.breakdowns
          .filter((breakdown) => breakdown.dimension === dimension)
          .reduce((total, breakdown) => total + breakdown.totals.requests, 0),
      ).toBe(rows.length);
    }
  });
});

function usageRow(_: unknown, index: number): StoredUsageHourlyFact {
  const codex = index % 2 === 0;
  return {
    device_id: "device-production-sized",
    bucket_start_utc: new Date(Date.UTC(2026, 6, 12, Math.floor(index / 3)))
      .toISOString()
      .replace(".000Z", "Z"),
    usage_date: `2026-07-${String(12 + (Math.floor(index / 34) % 20)).padStart(2, "0")}`,
    usage_hour: index % 24,
    aggregation_timezone: "UTC",
    agent: codex ? "codex" : "claude_code",
    billing_channel: codex ? "openai_direct" : "anthropic_direct",
    channel_source: "agent_default",
    model: codex ? "gpt-5.6-sol" : "claude-opus-4-6",
    context_bucket: "le_128k",
    service_tier: "unknown",
    speed: "unknown",
    inference_geo: "unknown",
    input_tokens: 100,
    cache_read_tokens: 0,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 0,
    cache_write_inferred_tokens: 0,
    output_tokens: 50,
    reasoning_tokens: 0,
    requests: 1,
    web_search_requests: 0,
    web_fetch_requests: 0,
    source_cost_covered_requests: 0,
  };
}
