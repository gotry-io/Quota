import { MODEL_CATALOG, type ModelCatalog, type UsageHourlyFact } from "@gotry-io/quota-protocol";
import { resolveModel, validateModelCatalog } from "../src/index.ts";
import { describe, expect, it } from "vitest";

describe("report-time model catalog", () => {
  it("validates the checked-in catalog and resolves exact canonical IDs", () => {
    expect(validateModelCatalog(MODEL_CATALOG)).toMatchObject({ valid: true });
    expect(resolveModel(MODEL_CATALOG, row("gpt-5.5"))).toBe("gpt-5.5");
  });

  it("requires exact provider, client, and date scope for aliases", () => {
    const alias = row("GPT-5.5[1m]");
    expect(resolveModel(MODEL_CATALOG, alias)).toBe("gpt-5.5");
    expect(
      resolveModel(MODEL_CATALOG, {
        ...alias,
        billing_channel: "openrouter",
      }),
    ).toBeUndefined();
    expect(
      resolveModel(MODEL_CATALOG, {
        ...alias,
        agent: "claude_code",
      }),
    ).toBeUndefined();
    expect(
      resolveModel(MODEL_CATALOG, {
        ...alias,
        bucket_start_utc: "2026-01-01T00:00:00Z",
      }),
    ).toBeUndefined();
  });

  it("keeps unknown model text unresolved and rejects overlapping aliases", () => {
    expect(resolveModel(MODEL_CATALOG, row("openrouter-3o[1m]"))).toBeUndefined();
    const invalid: ModelCatalog = {
      ...MODEL_CATALOG,
      models: [
        ...MODEL_CATALOG.models,
        {
          canonical_id: "other",
          aliases: [
            {
              reported_model: "GPT-5.5[1m]",
              provider: "openai",
              client: "codex",
              effective_from: "2026-05-01",
            },
          ],
        },
      ],
    };
    expect(validateModelCatalog(invalid)).toMatchObject({
      valid: false,
      issues: expect.arrayContaining([expect.objectContaining({ code: "ambiguous_aliases" })]),
    });
  });
});

function row(model: string): UsageHourlyFact {
  return {
    bucket_start_utc: "2026-08-10T00:00:00Z",
    usage_date: "2026-08-10",
    usage_hour: 0,
    agent: "codex",
    billing_channel: "openai_direct",
    channel_source: "explicit",
    model,
    context_bucket: "le_128k",
    service_tier: "unknown",
    speed: "unknown",
    inference_geo: "unknown",
    input_tokens: 10,
    cache_read_tokens: 0,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 0,
    cache_write_inferred_tokens: 0,
    output_tokens: 2,
    reasoning_tokens: 0,
    requests: 1,
    web_search_requests: 0,
    web_fetch_requests: 0,
    source_cost_covered_requests: 0,
  };
}
