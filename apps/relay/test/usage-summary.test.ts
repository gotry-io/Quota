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

  it("summarizes retained history without an hourly breakdown", () => {
    const rows = Array.from({ length: 1_500 }, usageRow);
    const summary = buildUsageSummary(
      { rows, coverage: [], truncated: false },
      { from: "2026-02-01", to: "2026-08-10" },
      "calculate",
      PRICING_CATALOG,
      false,
    );

    expect(summary.totals.requests).toBe(rows.length);
    expect(
      summary.breakdowns.some(
        ({ dimension }) => dimension === "usage_date" || dimension === "bucket_start_utc",
      ),
    ).toBe(false);
  });

  it("keeps totals when breakdown cardinality exceeds the response bound", () => {
    const rows = Array.from({ length: 1_001 }, (_, index) => {
      const row = usageRow(null, index, true);
      return { ...row, source_cost_microusd: "1", source_cost_covered_requests: 1 };
    });
    const summary = buildUsageSummary(
      { rows, coverage: [], truncated: false },
      { from: "2026-07-12", to: "2026-08-10" },
      "reported",
      PRICING_CATALOG,
    );

    expect(summary.totals.requests).toBe(rows.length);
    expect(summary.breakdowns.length).toBe(1_000);
    expect(summary.breakdowns_truncated).toBe(true);

    const legacySummary = buildUsageSummary(
      { rows, coverage: [], truncated: false, coverage_truncated: true },
      { from: "2026-07-12", to: "2026-08-10" },
      "reported",
      PRICING_CATALOG,
      true,
      false,
    );
    expect("coverage_truncated" in legacySummary).toBe(false);
    expect("breakdowns_truncated" in legacySummary).toBe(false);
  });

  it("keeps opaque punctuation in model breakdown keys", () => {
    const row = usageRow(null, 0, false);
    row.model = "provider:model[1m]";
    const summary = buildUsageSummary(
      { rows: [row], coverage: [], truncated: false },
      { from: "2026-08-10", to: "2026-08-10" },
      "reported",
      PRICING_CATALOG,
    );
    expect(summary.breakdowns).toContainEqual(
      expect.objectContaining({ dimension: "model", key: "provider:model[1m]" }),
    );
  });

  it("uses the protocol model bounds for breakdown keys", () => {
    for (const model of ["GPT-5.5[1m]", "😀".repeat(128)]) {
      const row = usageRow(null, 0, false);
      row.model = model;
      const summary = buildUsageSummary(
        { rows: [row], coverage: [], truncated: false },
        { from: "2026-08-10", to: "2026-08-10" },
        "reported",
        PRICING_CATALOG,
      );
      expect(summary.breakdowns).toContainEqual(
        expect.objectContaining({ dimension: "model", key: model }),
      );
    }

    for (const model of ["😀".repeat(129), "model\nwith-control"]) {
      const row = usageRow(null, 0, false);
      row.model = model;
      expect(() =>
        buildUsageSummary(
          { rows: [row], coverage: [], truncated: false },
          { from: "2026-08-10", to: "2026-08-10" },
          "reported",
          PRICING_CATALOG,
        ),
      ).toThrow();
    }
  });
});

function usageRow(_: unknown, index: number, uniqueModel = false): StoredUsageHourlyFact {
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
    model: uniqueModel ? `model-${index}` : codex ? "gpt-5.6-sol" : "claude-opus-4-6",
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
