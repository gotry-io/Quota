import { calculateUsageCost, validatePricingCatalog } from "@gotry-io/quota-model";
import type { UsageHourlyFact } from "@gotry-io/quota-protocol";
import { describe, expect, it } from "vitest";
import { PRICING_CATALOG, PRICING_CATALOG_ETAG } from "../src/pricing-catalog.ts";

describe("managed pricing catalog", () => {
  it("is a valid nonempty versioned catalog", () => {
    expect(validatePricingCatalog(PRICING_CATALOG)).toMatchObject({ valid: true });
    expect(PRICING_CATALOG.entries).toHaveLength(22);
    expect(PRICING_CATALOG_ETAG).toBe('"official-2026-08-10-1"');
  });

  it("prices verified OpenAI standard and Fast mode rows", () => {
    const standard = calculateUsageCost(
      [usageRow({ input_tokens: 1_000_000, output_tokens: 1_000_000 })],
      PRICING_CATALOG,
    );
    expect(standard).toMatchObject({
      status: "complete",
      amount_microusd: "35000000",
      assumptions: ["model_alias"],
    });

    const fastLong = calculateUsageCost(
      [
        usageRow({
          context_bucket: "gt_272k",
          service_tier: "priority",
          speed: "fast",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000,
        }),
      ],
      PRICING_CATALOG,
    );
    expect(fastLong).toMatchObject({ status: "complete", amount_microusd: "110000000" });
  });

  it("prices Anthropic cache, US inference, and tool dimensions", () => {
    const cost = calculateUsageCost(
      [
        usageRow({
          agent: "claude_code",
          billing_channel: "anthropic_direct",
          model: "claude-opus-4-6",
          context_bucket: "gt_272k",
          service_tier: "priority",
          speed: "fast",
          inference_geo: "us",
          input_tokens: 4_000_000,
          cache_read_tokens: 1_000_000,
          cache_write_5m_tokens: 1_000_000,
          cache_write_1h_tokens: 1_000_000,
          output_tokens: 1_000_000,
          web_search_requests: 2,
          web_fetch_requests: 1,
        }),
      ],
      PRICING_CATALOG,
    );
    expect(cost).toMatchObject({
      status: "complete",
      amount_microusd: "51445000",
      assumptions: ["wildcard_context_bucket"],
    });
  });

  it("does not backfill prices before their verified effective date", () => {
    const cost = calculateUsageCost(
      [
        usageRow({
          bucket_start_utc: "2026-08-09T00:00:00Z",
          usage_date: "2026-08-09",
          input_tokens: 1,
        }),
      ],
      PRICING_CATALOG,
    );
    expect(cost).toMatchObject({
      status: "unavailable",
      amount_microusd: null,
      unpriced: [{ reason: "outside_effective_range", rows: 1 }],
    });
  });
});

function usageRow(overrides: Partial<UsageHourlyFact>): UsageHourlyFact {
  return {
    bucket_start_utc: "2026-08-10T00:00:00Z",
    usage_date: "2026-08-10",
    usage_hour: 8,
    agent: "codex",
    billing_channel: "openai_direct",
    channel_source: "explicit",
    model: "gpt-5.6",
    context_bucket: "le_128k",
    service_tier: "standard",
    speed: "standard",
    inference_geo: "global",
    input_tokens: 0,
    cache_read_tokens: 0,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 0,
    cache_write_inferred_tokens: 0,
    output_tokens: 0,
    reasoning_tokens: 0,
    requests: 1,
    web_search_requests: 0,
    web_fetch_requests: 0,
    source_cost_covered_requests: 0,
    ...overrides,
  };
}
