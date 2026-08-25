import { MODEL_CATALOG } from "@gotry-io/quota-protocol";
import type { StoredUsageHourlyFact } from "@gotry-io/relay-core";
import { describe, expect, it } from "vitest";
import { PRICING_CATALOG } from "../src/pricing-catalog.ts";
import { buildUsageSummary } from "../src/usage-summary.ts";

describe("Usage summary", () => {
  it("folds a production-sized result into all six breakdowns without recomputing rows", () => {
    const rows = Array.from({ length: 796 }, usageRow);
    const summary = buildUsageSummary(
      { rows, coverage: "complete", truncated: false },
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
      { rows, coverage: "complete", truncated: false },
      { from: "2026-02-01", to: "2026-08-10" },
      "calculate",
      PRICING_CATALOG,
      false,
    );

    expect(summary.totals.requests).toBe(rows.length);
    expect(summary.breakdowns.some(({ dimension }) => dimension === "usage_date")).toBe(true);
    expect(summary.breakdowns.some(({ dimension }) => dimension === "bucket_start_utc")).toBe(
      false,
    );
  });

  it("keeps client and provider ownership when structured account Usage is requested", () => {
    const rows = [usageRow(null, 0), usageRow(null, 1)].map((row) => ({
      ...row,
      model: "shared-model",
      source_cost_microusd: "10",
      source_cost_covered_requests: 1,
    }));
    const structured = buildUsageSummary(
      { rows, coverage: "complete", truncated: false },
      { from: "2026-08-10", to: "2026-08-10" },
      "reported",
      PRICING_CATALOG,
      false,
      MODEL_CATALOG,
      true,
    );

    expect(structured.agents).toMatchObject([
      {
        agent: "claude_code",
        providers: [
          { provider: "anthropic", models: [{ model: "shared-model", totals: { messages: 1 } }] },
        ],
      },
      {
        agent: "codex",
        providers: [
          { provider: "openai", models: [{ model: "shared-model", totals: { messages: 1 } }] },
        ],
      },
    ]);
  });

  it("keeps totals when breakdown cardinality exceeds the response bound", () => {
    const rows = Array.from({ length: 1_001 }, (_, index) => {
      const row = usageRow(null, index, true);
      return { ...row, source_cost_microusd: "1", source_cost_covered_requests: 1 };
    });
    const summary = buildUsageSummary(
      { rows, coverage: "complete", truncated: false },
      { from: "2026-07-12", to: "2026-08-10" },
      "reported",
      PRICING_CATALOG,
    );

    expect(summary.totals.requests).toBe(rows.length);
    expect(summary.breakdowns.length).toBe(1_000);
    expect(summary.breakdowns_truncated).toBe(true);
  });

  it("keeps opaque punctuation in model breakdown keys", () => {
    const row = usageRow(null, 0, false);
    row.model = "provider:model[1m]";
    const summary = buildUsageSummary(
      { rows: [row], coverage: "complete", truncated: false },
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
        { rows: [row], coverage: "complete", truncated: false },
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
          { rows: [row], coverage: "complete", truncated: false },
          { from: "2026-08-10", to: "2026-08-10" },
          "reported",
          PRICING_CATALOG,
        ),
      ).toThrow();
    }
  });

  it("normalizes only model breakdown keys and leaves totals/cost unchanged", () => {
    const row = {
      ...usageRow(null, 0, false),
      model: "GPT-5.5[1m]",
      source_cost_microusd: "12",
      source_cost_covered_requests: 1,
    };
    const raw = buildUsageSummary(
      { rows: [row], coverage: "complete", truncated: false },
      { from: "2026-08-10", to: "2026-08-10" },
      "reported",
      PRICING_CATALOG,
      false,
    );
    const normalized = buildUsageSummary(
      { rows: [row], coverage: "complete", truncated: false },
      { from: "2026-08-10", to: "2026-08-10" },
      "reported",
      PRICING_CATALOG,
      false,
      MODEL_CATALOG,
    );
    expect(normalized.totals).toEqual(raw.totals);
    expect(normalized.cost).toEqual(raw.cost);
    expect(normalized.breakdowns.find((item) => item.dimension === "model")?.key).toBe("gpt-5.5");
    expect(normalized.model_catalog_revision).toBe(MODEL_CATALOG.revision);

    const calculated = buildUsageSummary(
      { rows: [row], coverage: "complete", truncated: false },
      { from: "2026-08-10", to: "2026-08-10" },
      "calculate",
      PRICING_CATALOG,
      false,
      MODEL_CATALOG,
    );
    expect(calculated.cost).toMatchObject({ unpriced_rows: 1 });
    expect(calculated.cost.unpriced).toEqual([
      expect.objectContaining({ model: "GPT-5.5[1m]", reason: "unknown_model" }),
    ]);
  });

  it("regroups retained rows when only the catalog revision changes", () => {
    const row = { ...usageRow(null, 0, false), model: "GPT-5.5[1m]" };
    const beforeCatalog = {
      ...MODEL_CATALOG,
      revision: "model-before-alias",
      models: MODEL_CATALOG.models.map((model) =>
        model.canonical_id === "gpt-5.5" ? { ...model, aliases: [] } : model,
      ),
    };
    const summarize = (modelCatalog: typeof MODEL_CATALOG) =>
      buildUsageSummary(
        { rows: [row], coverage: "complete", truncated: false },
        { from: "2026-08-10", to: "2026-08-10" },
        "reported",
        PRICING_CATALOG,
        false,
        modelCatalog,
      );

    const before = summarize(beforeCatalog);
    const after = summarize(MODEL_CATALOG);
    expect(before.breakdowns.find((item) => item.dimension === "model")?.key).toBe("GPT-5.5[1m]");
    expect(after.breakdowns.find((item) => item.dimension === "model")?.key).toBe("gpt-5.5");
    expect(after.totals).toEqual(before.totals);
    expect(after.cost).toEqual(before.cost);
    expect(row.model).toBe("GPT-5.5[1m]");
  });

  it("keeps a raw model separate when it collides with a display name", () => {
    const rows = [
      { ...usageRow(null, 0, false), model: "gpt-5.5" },
      { ...usageRow(null, 1, false), model: "GPT-5.5" },
    ];
    const summary = buildUsageSummary(
      { rows, coverage: "complete", truncated: false },
      { from: "2026-08-10", to: "2026-08-10" },
      "reported",
      PRICING_CATALOG,
      false,
      MODEL_CATALOG,
    );
    const modelGroups = summary.breakdowns.filter((item) => item.dimension === "model");
    expect(modelGroups).toHaveLength(2);
    expect(modelGroups.map((item) => item.totals.requests)).toEqual([1, 1]);
    expect(modelGroups.map((item) => item.key)).toEqual(["gpt-5.5", "GPT-5.5"]);
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
