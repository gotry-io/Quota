import {
  type PricingCatalog,
  type PricingCatalogEntry,
  PricingCatalogSchema,
  type PricingRates,
} from "@gotry-io/quota-protocol";

const EFFECTIVE_FROM = "2026-08-10";
const VERIFIED_AT = "2026-08-10T00:00:00.000Z";
const OPENAI_MODEL_SOURCE = "https://developers.openai.com/api/docs/models/gpt-5.6-sol";
const OPENAI_FAST_SOURCE = "https://openai.com/api-fast-mode/";
const ANTHROPIC_SOURCE = "https://platform.claude.com/docs/en/about-claude/pricing";

const openAIContexts = [
  {
    bucket: "le_128k",
    standard: ["5", "0.5", "6.25", "30"],
    fast: ["10", "1", "12.5", "60"],
  },
  {
    bucket: "gt_128k_le_200k",
    standard: ["5", "0.5", "6.25", "30"],
    fast: ["10", "1", "12.5", "60"],
  },
  {
    bucket: "gt_200k_le_256k",
    standard: ["5", "0.5", "6.25", "30"],
    fast: ["10", "1", "12.5", "60"],
  },
  {
    bucket: "gt_256k_le_272k",
    standard: ["5", "0.5", "6.25", "30"],
    fast: ["10", "1", "12.5", "60"],
  },
  {
    bucket: "gt_272k",
    standard: ["10", "1", "12.5", "45"],
    fast: ["20", "2", "25", "90"],
  },
] as const;

const anthropicModels = [
  {
    model: "claude-opus-4-6",
    global: ["5", "0.5", "6.25", "10", "25"],
    us: ["5.5", "0.55", "6.875", "11", "27.5"],
  },
  {
    model: "claude-sonnet-4-6",
    global: ["3", "0.3", "3.75", "6", "15"],
    us: ["3.3", "0.33", "4.125", "6.6", "16.5"],
  },
] as const;

function tokenRates(
  input: string,
  cacheRead: string,
  cacheWrite5m: string,
  cacheWrite1h: string,
  output: string,
  tools = false,
): PricingRates {
  return {
    uncached_input_per_million: input,
    cache_read_per_million: cacheRead,
    cache_write_5m_per_million: cacheWrite5m,
    cache_write_1h_per_million: cacheWrite1h,
    cache_write_inferred_per_million: cacheWrite5m,
    output_per_million: output,
    web_search_per_request: tools ? "0.01" : null,
    web_fetch_per_request: tools ? "0" : null,
  };
}

function openAIEntries(): PricingCatalogEntry[] {
  return openAIContexts.flatMap(({ bucket, standard, fast }) => [
    {
      entry_id: `openai-gpt-5.6-sol-standard-${bucket}`,
      billing_channel: "openai_direct",
      model: "gpt-5.6-sol",
      aliases: ["gpt-5.6"],
      effective_from: EFFECTIVE_FROM,
      effective_to: null,
      service_tier: "standard",
      speed: "standard",
      inference_geo: "global",
      context_bucket: bucket,
      currency: "USD",
      rates: tokenRates(standard[0], standard[1], standard[2], standard[2], standard[3]),
      source_url: OPENAI_MODEL_SOURCE,
      verified_at: VERIFIED_AT,
    },
    {
      entry_id: `openai-gpt-5.6-sol-fast-${bucket}`,
      billing_channel: "openai_direct",
      model: "gpt-5.6-sol",
      aliases: ["gpt-5.6"],
      effective_from: EFFECTIVE_FROM,
      effective_to: null,
      service_tier: "priority",
      speed: "fast",
      inference_geo: "global",
      context_bucket: bucket,
      currency: "USD",
      rates: tokenRates(fast[0], fast[1], fast[2], fast[2], fast[3]),
      source_url: OPENAI_FAST_SOURCE,
      verified_at: VERIFIED_AT,
    },
  ]);
}

function anthropicEntries(): PricingCatalogEntry[] {
  return anthropicModels.flatMap(({ model, global, us }) => {
    const configurations =
      model === "claude-opus-4-6"
        ? ([
            ["standard", "standard"],
            ["standard", "fast"],
            ["priority", "standard"],
            ["priority", "fast"],
          ] as const)
        : ([
            ["standard", "standard"],
            ["priority", "standard"],
          ] as const);
    return configurations.flatMap(([serviceTier, speed]) =>
      (["global", "us"] as const).map((inferenceGeo) => {
        const rates = inferenceGeo === "us" ? us : global;
        return {
          entry_id: `anthropic-${model}-${serviceTier}-${speed}-${inferenceGeo}`,
          billing_channel: "anthropic_direct",
          model,
          aliases: [],
          effective_from: EFFECTIVE_FROM,
          effective_to: null,
          service_tier: serviceTier,
          speed,
          inference_geo: inferenceGeo,
          context_bucket: "*",
          currency: "USD",
          rates: tokenRates(rates[0], rates[1], rates[2], rates[3], rates[4], true),
          source_url: ANTHROPIC_SOURCE,
          verified_at: VERIFIED_AT,
        } satisfies PricingCatalogEntry;
      }),
    );
  });
}

export const PRICING_CATALOG: PricingCatalog = PricingCatalogSchema.parse({
  protocol_version: 2,
  revision: "official-2026-08-10-1",
  published_at: VERIFIED_AT,
  entries: [...openAIEntries(), ...anthropicEntries()],
});

export const PRICING_CATALOG_ETAG = `"${PRICING_CATALOG.revision}"`;
