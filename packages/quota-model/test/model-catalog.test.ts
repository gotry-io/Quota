import { type DatedUsageRow, MODEL_CATALOG, type ModelCatalog } from "@gotry-io/quota-protocol";
import { resolveModel, resolveProvider, validateModelCatalog } from "../src/index.ts";
import { describe, expect, it } from "vitest";

describe("report-time model catalog", () => {
  it("validates the checked-in catalog and resolves exact canonical IDs", () => {
    expect(validateModelCatalog(MODEL_CATALOG)).toMatchObject({ valid: true });
    expect(resolveModel(MODEL_CATALOG, row("gpt-5.5"))).toBe("gpt-5.5");
  });

  it("requires exact provider, client, and date scope for aliases", () => {
    const alias = row("GPT-5.5[1m]");
    expect(resolveModel(MODEL_CATALOG, alias)).toBe("gpt-5.5");
    // The alias is scoped to OpenAI, and the name says OpenAI whoever billed it.
    expect(
      resolveModel(MODEL_CATALOG, {
        ...alias,
        billing_channel: "openrouter",
      }),
    ).toBe("gpt-5.5");
    expect(
      resolveModel(MODEL_CATALOG, {
        ...alias,
        agent: "claude_code",
      }),
    ).toBeUndefined();
    expect(
      resolveModel(MODEL_CATALOG, {
        ...alias,
        date: "2026-01-01",
      }),
    ).toBeUndefined();
  });

  it("names a model's vendor from its name alone; the channel is not an input", () => {
    expect(resolveProvider(MODEL_CATALOG, row("grok-4.5"))).toBe("xai");
    expect(resolveProvider(MODEL_CATALOG, row("Claude-Opus-5"))).toBe("anthropic");
    expect(resolveProvider(MODEL_CATALOG, row("k2p5"))).toBe("moonshot");
    expect(resolveProvider(MODEL_CATALOG, row("gemini-3-pro"))).toBe("google");
    expect(resolveProvider(MODEL_CATALOG, row("composer-1.5"))).toBe("cursor");
    // An endpoint alias names no vendor, whichever provider id reached it.
    expect(resolveProvider(MODEL_CATALOG, row("ep-20260811103923-jzct4"))).toBe("unknown");
    expect(resolveProvider(MODEL_CATALOG, row("big-pickle"))).toBe("unknown");
  });

  it("takes the longest family and rejects a duplicate or misspelt one", () => {
    const layered: ModelCatalog = {
      ...MODEL_CATALOG,
      families: [
        { prefix: "g", provider: "google" },
        { prefix: "gpt-", provider: "openai" },
      ],
    };
    expect(validateModelCatalog(layered)).toMatchObject({ valid: true });
    expect(resolveProvider(layered, row("gpt-5.5"))).toBe("openai");
    expect(resolveProvider(layered, row("gemma-4"))).toBe("google");
    expect(
      validateModelCatalog({
        ...MODEL_CATALOG,
        families: [
          { prefix: "grok", provider: "xai" },
          { prefix: "grok", provider: "xai" },
        ],
      }),
    ).toMatchObject({
      valid: false,
      issues: [{ code: "duplicate_family_prefix", prefix: "grok" }],
    });
    expect(
      validateModelCatalog({
        ...MODEL_CATALOG,
        families: [{ prefix: "GPT-", provider: "openai" }],
      }),
    ).toMatchObject({ valid: false });
  });

  it("maps grok CLI build names onto the canonical Grok models from their launch dates", () => {
    expect(
      resolveModel(MODEL_CATALOG, {
        ...row("grok-4.6-build"),
        agent: "grok",
        date: "2026-08-12",
      }),
    ).toBe("grok-4.6");
    expect(
      resolveModel(MODEL_CATALOG, {
        ...row("grok-4.5-build"),
        agent: "grok",
      }),
    ).toBe("grok-4.5");
    expect(
      resolveModel(MODEL_CATALOG, {
        ...row("grok-4.6-build"),
        agent: "grok",
        date: "2026-08-11",
      }),
    ).toBeUndefined();
  });

  it("maps OpenCode k2p5 onto kimi-k2.5 from the generation start", () => {
    expect(
      resolveModel(MODEL_CATALOG, {
        ...row("k2p5"),
        agent: "opencode",
        date: "2026-02-01",
      }),
    ).toBe("kimi-k2.5");
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
              agent: "codex",
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

function row(model: string): DatedUsageRow {
  return {
    date: "2026-08-10",
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
