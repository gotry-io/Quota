import { calculateUsageCost, validatePricingCatalog } from "@gotry-io/quota-model";
import type { UsageHourlyFact } from "@gotry-io/quota-protocol";
import { describe, expect, it } from "vitest";
import { PRICING_CATALOG, PRICING_CATALOG_ETAG } from "../src/pricing-catalog.ts";

describe("managed pricing catalog", () => {
  it("is a valid versioned snapshot covering the collected models", () => {
    expect(validatePricingCatalog(PRICING_CATALOG)).toMatchObject({ valid: true });
    expect(new Set(PRICING_CATALOG.entries.map((entry) => entry.model))).toEqual(
      new Set([
        "gpt-5.2-codex",
        "gpt-5.3-codex",
        "gpt-5.4",
        "gpt-5.5",
        "gpt-5.6-sol",
        "gpt-5.6-luna",
        "grok-4.5",
        "claude-opus-4-6",
        "claude-sonnet-4-6",
      ]),
    );
    expect(PRICING_CATALOG_ETAG).toBe('"official-2026-08-10-4"');
  });

  it("prices Grok 4.5 short and long context rows", () => {
    for (const [context_bucket, amount_microusd] of [
      ["le_128k", "8000000"],
      ["gt_272k", "16000000"],
    ] as const) {
      expect(
        calculateUsageCost(
          [
            usageRow({
              agent: "grok",
              billing_channel: "xai_direct",
              model: "grok-4.5",
              context_bucket,
              input_tokens: 1_000_000,
              output_tokens: 1_000_000,
            }),
          ],
          PRICING_CATALOG,
        ),
      ).toMatchObject({ status: "complete", amount_microusd });
    }
  });

  it("prices the collected GPT-5.4, GPT-5.5, and effective-dated GPT-5.6 Luna rows", () => {
    for (const [model, date, amount] of [
      ["gpt-5.4", "2026-03-06", "17500000"],
      ["gpt-5.5", "2026-04-24", "35000000"],
      ["gpt-5.6-luna", "2026-07-29", "7000000"],
      ["gpt-5.6-luna", "2026-07-30", "1400000"],
    ] as const) {
      expect(
        calculateUsageCost(
          [
            usageRow({
              model,
              bucket_start_utc: `${date}T00:00:00Z`,
              usage_date: date,
              input_tokens: 1_000_000,
              output_tokens: 1_000_000,
            }),
          ],
          PRICING_CATALOG,
        ),
      ).toMatchObject({ status: "complete", amount_microusd: amount });
    }
  });

  it("prices the actual Codex models when parser dimensions are unknown", () => {
    for (const model of ["gpt-5.2-codex", "gpt-5.3-codex"]) {
      const cost = calculateUsageCost(
        [
          usageRow({
            model,
            input_tokens: 1_000_000,
            output_tokens: 1_000_000,
          }),
        ],
        PRICING_CATALOG,
      );
      expect(cost).toMatchObject({
        status: "complete",
        amount_microusd: "15750000",
        assumptions: [
          "agent_default_channel",
          "wildcard_context_bucket",
          "wildcard_inference_geo",
          "wildcard_service_tier",
          "wildcard_speed",
        ],
      });
    }
  });

  it("prices actual Codex parser dimensions with an explicit inferred-cache approximation", () => {
    const cost = calculateUsageCost(
      [
        usageRow({
          model: "gpt-5.2-codex",
          input_tokens: 1_000,
          cache_read_tokens: 200,
          cache_write_inferred_tokens: 100,
          output_tokens: 200,
        }),
        usageRow({
          model: "gpt-5.3-codex",
          context_bucket: "gt_128k_le_200k",
          service_tier: "priority",
          speed: "fast",
          input_tokens: 130_000,
          cache_read_tokens: 300,
          cache_write_inferred_tokens: 50,
          output_tokens: 300,
        }),
        usageRow({ model: "not-a-real-model", input_tokens: 10, output_tokens: 2 }),
      ],
      PRICING_CATALOG,
    );

    expect(cost).toMatchObject({
      status: "partial",
      amount_microusd: "235463",
      calculated_rows: 2,
      unpriced_rows: 1,
      assumptions: [
        "agent_default_channel",
        "cache_write_inferred_rate",
        "wildcard_context_bucket",
        "wildcard_inference_geo",
        "wildcard_service_tier",
        "wildcard_speed",
      ],
      unpriced: [
        {
          billing_channel: "openai_direct",
          model: "not-a-real-model",
          reason: "unknown_model",
        },
      ],
    });
  });

  it("prices OpenAI short/long and fast tiers without guessing unsupported tiers", () => {
    const standard = calculateUsageCost(
      [
        usageRow({
          model: "gpt-5.6-sol",
          service_tier: "standard",
          speed: "standard",
          inference_geo: "global",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000,
        }),
      ],
      PRICING_CATALOG,
    );
    expect(standard).toMatchObject({
      status: "complete",
      amount_microusd: "35000000",
    });

    const fastLong = calculateUsageCost(
      [
        usageRow({
          model: "gpt-5.6",
          context_bucket: "gt_272k",
          service_tier: "priority",
          speed: "fast",
          inference_geo: "global",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000,
        }),
      ],
      PRICING_CATALOG,
    );
    expect(fastLong).toMatchObject({
      status: "complete",
      amount_microusd: "110000000",
      assumptions: ["agent_default_channel", "model_alias", "wildcard_inference_geo"],
    });

    expect(
      calculateUsageCost(
        [usageRow({ model: "gpt-5.6-sol", service_tier: "flex", speed: "unknown" })],
        PRICING_CATALOG,
      ),
    ).toMatchObject({ status: "unavailable", unpriced: [{ reason: "unsupported_dimensions" }] });
  });

  it("prices Anthropic cache, US inference, tools, and unknown parser dimensions", () => {
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
        usageRow({
          agent: "claude_code",
          billing_channel: "anthropic_direct",
          model: "claude-sonnet-4-6",
          service_tier: "unknown",
          speed: "unknown",
          inference_geo: "unknown",
          input_tokens: 1,
          output_tokens: 1,
        }),
      ],
      PRICING_CATALOG,
    );
    expect(cost).toMatchObject({
      status: "complete",
      amount_microusd: "51445018",
      assumptions: [
        "agent_default_channel",
        "wildcard_context_bucket",
        "wildcard_inference_geo",
        "wildcard_service_tier",
      ],
    });
  });

  it("uses the historical Opus long-context price before the standard-price change", () => {
    const before = calculateUsageCost(
      [
        usageRow({
          agent: "claude_code",
          billing_channel: "anthropic_direct",
          model: "claude-opus-4-6",
          bucket_start_utc: "2026-03-12T00:00:00Z",
          usage_date: "2026-03-12",
          context_bucket: "gt_272k",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000,
        }),
      ],
      PRICING_CATALOG,
    );
    const atBoundary = calculateUsageCost(
      [
        usageRow({
          agent: "claude_code",
          billing_channel: "anthropic_direct",
          model: "claude-opus-4-6",
          bucket_start_utc: "2026-03-13T00:00:00Z",
          usage_date: "2026-03-13",
          context_bucket: "gt_272k",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000,
        }),
      ],
      PRICING_CATALOG,
    );
    expect(before).toMatchObject({ status: "complete", amount_microusd: "47500000" });
    expect(atBoundary).toMatchObject({ status: "complete", amount_microusd: "30000000" });
  });

  it("does not backfill prices before a model release and leaves synthetic models unpriced", () => {
    expect(
      calculateUsageCost(
        [
          usageRow({
            model: "gpt-5.2-codex",
            bucket_start_utc: "2025-12-10T00:00:00Z",
            usage_date: "2025-12-10",
            input_tokens: 1,
          }),
        ],
        PRICING_CATALOG,
      ),
    ).toMatchObject({
      status: "unavailable",
      amount_microusd: null,
      unpriced: [{ reason: "outside_effective_range", rows: 1 }],
    });
    expect(
      calculateUsageCost(
        [
          usageRow({
            agent: "claude_code",
            billing_channel: "anthropic_direct",
            model: "synthetic",
          }),
        ],
        PRICING_CATALOG,
      ),
    ).toMatchObject({
      status: "unavailable",
      amount_microusd: null,
      unpriced: [{ reason: "unknown_model", rows: 1 }],
    });
  });
});

function usageRow(overrides: Partial<UsageHourlyFact> = {}): UsageHourlyFact {
  return {
    bucket_start_utc: "2026-08-10T00:00:00Z",
    usage_date: "2026-08-10",
    usage_hour: 8,
    agent: "codex",
    billing_channel: "openai_direct",
    channel_source: "agent_default",
    model: "gpt-5.3-codex",
    context_bucket: "le_128k",
    service_tier: "unknown",
    speed: "unknown",
    inference_geo: "unknown",
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
