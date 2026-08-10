import {
  type PricingCatalog,
  type PricingCatalogEntry,
  PricingCatalogSchema,
  type PricingRates,
} from "@gotry-io/quota-protocol";

/**
 * This catalog is a checked-in snapshot.  It deliberately has no runtime
 * dependency on models.dev or either provider's pricing page.
 *
 * models.dev is MIT licensed (copyright 2025 models.dev).  Its provider TOMLs
 * are the source for the model IDs, release dates, and the historical Opus
 * long-context tier.  The current models.dev API/TOMLs are not a complete
 * pricing history; the effective-date changes below are pinned to the cited
 * provider pages and the historical models.dev commit where applicable.
 *
 * Relevant models.dev snapshots:
 * - https://raw.githubusercontent.com/anomalyco/models.dev/5c281e4febe6/providers/openai/models/gpt-5.2-codex.toml
 * - https://raw.githubusercontent.com/anomalyco/models.dev/5c281e4febe6/providers/openai/models/gpt-5.3-codex.toml
 * - https://raw.githubusercontent.com/anomalyco/models.dev/6dfc39c81b6cd57a91c155aa7b4f68ed1b360da0/providers/openai/models/gpt-5.6-sol.toml
 * - https://raw.githubusercontent.com/anomalyco/models.dev/921ec8f8fcc9/providers/anthropic/models/claude-opus-4-6.toml
 * - https://raw.githubusercontent.com/anomalyco/models.dev/a39260825d360f08eb3af659516e5be9f93e7836/providers/anthropic/models/claude-opus-4-6.toml
 * - https://raw.githubusercontent.com/anomalyco/models.dev/df3fa55fefea90465335c9489d52721c16d89284/providers/anthropic/models/claude-sonnet-4-6.toml
 *
 * The source repository is available at https://github.com/anomalyco/models.dev
 * and its license is https://github.com/anomalyco/models.dev/blob/dev/LICENSE.
 */

const VERIFIED_AT = "2026-08-10T00:00:00.000Z";
const OPENAI_PRICING_SOURCE = "https://developers.openai.com/api/docs/pricing";
const OPENAI_CODEX_52_SOURCE = "https://developers.openai.com/api/docs/models/gpt-5.2-codex";
const OPENAI_CODEX_53_SOURCE = "https://developers.openai.com/api/docs/models/gpt-5.3-codex";
const OPENAI_SOL_SOURCE = "https://developers.openai.com/api/docs/models/gpt-5.6-sol";
const ANTHROPIC_PRICING_SOURCE = "https://platform.claude.com/docs/en/about-claude/pricing";
const ANTHROPIC_OPUS_46_SOURCE = "https://www.anthropic.com/news/claude-opus-4-6";
const ANTHROPIC_RELEASE_NOTES_SOURCE = "https://platform.claude.com/docs/en/release-notes/overview";

const CONTEXT_BUCKETS = [
  "le_128k",
  "gt_128k_le_200k",
  "gt_200k_le_256k",
  "gt_256k_le_272k",
  "gt_272k",
] as const;

type ContextBucket = (typeof CONTEXT_BUCKETS)[number];
const SHORT_AND_LONG_CONTEXTS = ["*", "gt_272k"] as const;

const STANDARD_SERVICE_TIERS = ["standard", "unknown"] as const;
const STANDARD_SPEEDS = ["standard", "unknown"] as const;
const ANTHROPIC_SERVICE_TIERS = ["standard", "priority", "unknown"] as const;

function tokenRates(
  input: string,
  cacheRead: string,
  cacheWrite5m: string | null,
  cacheWrite1h: string | null,
  output: string,
  tools = false,
  cacheWriteInferred = cacheWrite5m,
): PricingRates {
  return {
    uncached_input_per_million: input,
    cache_read_per_million: cacheRead,
    cache_write_5m_per_million: cacheWrite5m,
    cache_write_1h_per_million: cacheWrite1h,
    cache_write_inferred_per_million: cacheWriteInferred,
    output_per_million: output,
    web_search_per_request: tools ? "0.01" : null,
    web_fetch_per_request: tools ? "0" : null,
  };
}

function scaledRates(rates: PricingRates): PricingRates {
  const scale = (value: string | null): string | null =>
    value === null ? null : multiplyByElevenTenths(value);
  return {
    uncached_input_per_million: scale(rates.uncached_input_per_million),
    cache_read_per_million: scale(rates.cache_read_per_million),
    cache_write_5m_per_million: scale(rates.cache_write_5m_per_million),
    cache_write_1h_per_million: scale(rates.cache_write_1h_per_million),
    cache_write_inferred_per_million: scale(rates.cache_write_inferred_per_million),
    output_per_million: scale(rates.output_per_million),
    web_search_per_request: rates.web_search_per_request,
    web_fetch_per_request: rates.web_fetch_per_request,
  };
}

function multiplyByElevenTenths(value: string): string {
  const [integer = "0", fraction = ""] = value.split(".");
  const scale = fraction.length + 1;
  const numerator = BigInt(`${integer}${fraction}`) * 11n;
  const raw = numerator.toString().padStart(scale + 1, "0");
  const point = raw.length - scale;
  const whole = raw.slice(0, point);
  const decimal = raw.slice(point).replace(/0+$/, "");
  return decimal.length === 0 ? whole : `${whole}.${decimal}`;
}

interface EntryExpansion {
  entryPrefix: string;
  model: string;
  aliases?: readonly string[];
  effectiveFrom: string;
  effectiveTo: string | null;
  serviceTiers: readonly string[];
  speeds: readonly string[];
  inferenceGeos: readonly string[];
  contexts: readonly (ContextBucket | "*")[];
  rates: PricingRates | ((context: ContextBucket | "*") => PricingRates);
  sourceUrl: string;
}

function expandEntries(input: EntryExpansion): PricingCatalogEntry[] {
  return input.serviceTiers.flatMap((serviceTier) =>
    input.speeds.flatMap((speed) =>
      input.inferenceGeos.flatMap((inferenceGeo) =>
        input.contexts.map((contextBucket) => {
          const entry = {
            entry_id: [
              input.entryPrefix,
              input.effectiveFrom,
              serviceTier === "*" ? "any" : serviceTier,
              speed === "*" ? "any" : speed,
              inferenceGeo === "*" ? "any" : inferenceGeo,
              contextBucket === "*" ? "any" : contextBucket,
            ].join("-"),
            billing_channel: input.model.startsWith("claude-")
              ? "anthropic_direct"
              : "openai_direct",
            model: input.model,
            aliases: [...(input.aliases ?? [])],
            effective_from: input.effectiveFrom,
            effective_to: input.effectiveTo,
            service_tier: serviceTier,
            speed,
            inference_geo: inferenceGeo,
            context_bucket: contextBucket,
            currency: "USD",
            rates: typeof input.rates === "function" ? input.rates(contextBucket) : input.rates,
            source_url: input.sourceUrl,
            verified_at: VERIFIED_AT,
          } satisfies PricingCatalogEntry;
          return entry;
        }),
      ),
    ),
  );
}

function openAIStandardRates(
  input: string,
  cacheRead: string,
  cacheWrite: string | null,
  output: string,
  cacheWriteInferred = cacheWrite,
): PricingRates {
  return tokenRates(input, cacheRead, cacheWrite, cacheWrite, output, false, cacheWriteInferred);
}

function openAIEntries(): PricingCatalogEntry[] {
  const entries: PricingCatalogEntry[] = [];

  // GPT-5.2/5.3 Codex have one documented API rate independent of context
  // length.  No separate service/speed/geo/context rates are published, so
  // one explicit wildcard entry is the closest documented approximation.
  // Codex's parser reports an inferred cache-write bucket; use the uncached
  // input rate for that bucket as an explicit approximation, while retaining
  // null for the undocumented 5m/1h cache-write buckets.
  for (const model of [
    {
      model: "gpt-5.2-codex",
      effectiveFrom: "2025-12-11",
      sourceUrl: OPENAI_CODEX_52_SOURCE,
      prefix: "openai-gpt-5.2-codex",
    },
    {
      model: "gpt-5.3-codex",
      effectiveFrom: "2026-02-05",
      sourceUrl: OPENAI_CODEX_53_SOURCE,
      prefix: "openai-gpt-5.3-codex",
    },
  ]) {
    entries.push(
      ...expandEntries({
        entryPrefix: model.prefix,
        model: model.model,
        effectiveFrom: model.effectiveFrom,
        effectiveTo: null,
        serviceTiers: ["*"],
        speeds: ["*"],
        inferenceGeos: ["*"],
        contexts: ["*"],
        rates: openAIStandardRates("1.75", "0.175", null, "14", "1.75"),
        sourceUrl: model.sourceUrl,
      }),
    );
  }

  const solContexts = (context: ContextBucket | "*"): PricingRates => {
    const long = context === "gt_272k";
    return openAIStandardRates(
      long ? "10" : "5",
      long ? "1" : "0.5",
      long ? "12.5" : "6.25",
      long ? "45" : "30",
    );
  };
  const solFastContexts = (context: ContextBucket | "*"): PricingRates => {
    const long = context === "gt_272k";
    return openAIStandardRates(
      long ? "20" : "10",
      long ? "2" : "1",
      long ? "25" : "12.5",
      long ? "90" : "60",
    );
  };

  // GPT-5.6 Sol launched on 2026-07-09.  OpenAI documents short/long
  // pricing with the long tier beginning after the 272k billable-input cap.
  // The standard entries retain the parser's known standard/unknown
  // dimensions so unsupported flex/fast combinations are not silently priced.
  entries.push(
    ...expandEntries({
      entryPrefix: "openai-gpt-5.6-sol-standard",
      model: "gpt-5.6-sol",
      aliases: ["gpt-5.6"],
      effectiveFrom: "2026-07-09",
      effectiveTo: null,
      serviceTiers: STANDARD_SERVICE_TIERS,
      speeds: STANDARD_SPEEDS,
      inferenceGeos: ["*"],
      contexts: SHORT_AND_LONG_CONTEXTS,
      rates: solContexts,
      sourceUrl: OPENAI_SOL_SOURCE,
    }),
    ...expandEntries({
      entryPrefix: "openai-gpt-5.6-sol-fast",
      model: "gpt-5.6-sol",
      aliases: ["gpt-5.6"],
      effectiveFrom: "2026-07-09",
      effectiveTo: null,
      serviceTiers: ["priority"],
      speeds: ["fast"],
      inferenceGeos: ["*"],
      contexts: SHORT_AND_LONG_CONTEXTS,
      rates: solFastContexts,
      sourceUrl: OPENAI_PRICING_SOURCE,
    }),
  );

  return entries;
}

function anthropicRates(
  input: string,
  cacheRead: string,
  cacheWrite5m: string | null,
  cacheWrite1h: string | null,
  output: string,
): PricingRates {
  return tokenRates(input, cacheRead, cacheWrite5m, cacheWrite1h, output, true, cacheWrite5m);
}

function anthropicEntries(): PricingCatalogEntry[] {
  const entries: PricingCatalogEntry[] = [];

  type AnthropicExpansion = Omit<
    EntryExpansion,
    "model" | "entryPrefix" | "rates" | "inferenceGeos"
  > & {
    model: string;
    entryPrefix: string;
    rates: PricingRates | ((context: ContextBucket | "*") => PricingRates);
    inferenceGeos?: readonly string[];
  };

  const expandAnthropic = (input: AnthropicExpansion) =>
    expandEntries({
      ...input,
      inferenceGeos: input.inferenceGeos ?? ["*"],
    });

  const expandAnthropicWithUs = (input: AnthropicExpansion): PricingCatalogEntry[] => {
    const rates = input.rates;
    const usRates =
      typeof rates === "function"
        ? (context: ContextBucket | "*") => scaledRates(rates(context))
        : scaledRates(rates);
    return [
      ...expandAnthropic({ ...input, inferenceGeos: ["*"] }),
      ...expandAnthropic({
        ...input,
        entryPrefix: `${input.entryPrefix}-us`,
        serviceTiers: ANTHROPIC_SERVICE_TIERS,
        inferenceGeos: ["us"],
        rates: usRates,
      }),
    ];
  };

  const standardOpus = anthropicRates("5", "0.5", "6.25", "10", "25");
  const standardSonnet = anthropicRates("3", "0.3", "3.75", "6", "15");

  // Opus 4.6 launched with a premium for requests over 200k input tokens.
  // models.dev recorded the exact historical tier at commit 921ec8f8fcc9;
  // Anthropic announced the same $10/$37.50 input/output prices.  The 1h
  // long-context cache-write rate was not published in that historical source,
  // so it remains unpriced instead of being inferred.
  const opusHistoricalStandard = (context: ContextBucket | "*") =>
    context === "gt_200k_le_256k" || context === "gt_256k_le_272k" || context === "gt_272k"
      ? anthropicRates("10", "1", "12.5", null, "37.5")
      : standardOpus;
  entries.push(
    ...expandAnthropicWithUs({
      entryPrefix: "anthropic-claude-opus-4-6-standard-historical",
      model: "claude-opus-4-6",
      effectiveFrom: "2026-02-05",
      effectiveTo: "2026-03-13",
      serviceTiers: ["*"],
      speeds: ["standard", "unknown"],
      contexts: ["*", "gt_200k_le_256k", "gt_256k_le_272k", "gt_272k"],
      rates: opusHistoricalStandard,
      sourceUrl: ANTHROPIC_OPUS_46_SOURCE,
    }),
    ...expandAnthropicWithUs({
      entryPrefix: "anthropic-claude-opus-4-6-fast-historical",
      model: "claude-opus-4-6",
      effectiveFrom: "2026-02-07",
      effectiveTo: "2026-06-29",
      serviceTiers: ["*"],
      speeds: ["fast"],
      contexts: ["*"],
      rates: anthropicRates("30", "3", "37.5", null, "150"),
      sourceUrl: ANTHROPIC_RELEASE_NOTES_SOURCE,
    }),
  );

  // On 2026-03-13 Anthropic made 1M context standard-priced.  On 2026-06-29
  // Opus fast mode was removed; requests that still carry speed=fast run and
  // are billed at standard rates.  Keep those dimensions so historical local
  // rows remain calculable without applying a premium that no longer exists.
  entries.push(
    ...expandAnthropicWithUs({
      entryPrefix: "anthropic-claude-opus-4-6-standard",
      model: "claude-opus-4-6",
      effectiveFrom: "2026-03-13",
      effectiveTo: null,
      serviceTiers: ["*"],
      speeds: ["standard", "unknown"],
      contexts: ["*"],
      rates: standardOpus,
      sourceUrl: ANTHROPIC_PRICING_SOURCE,
    }),
    ...expandAnthropicWithUs({
      entryPrefix: "anthropic-claude-opus-4-6-fast-standard",
      model: "claude-opus-4-6",
      effectiveFrom: "2026-06-29",
      effectiveTo: null,
      serviceTiers: ["*"],
      speeds: ["fast"],
      contexts: ["*"],
      rates: standardOpus,
      sourceUrl: ANTHROPIC_RELEASE_NOTES_SOURCE,
    }),
    ...expandAnthropicWithUs({
      entryPrefix: "anthropic-claude-sonnet-4-6-standard",
      model: "claude-sonnet-4-6",
      effectiveFrom: "2026-02-17",
      effectiveTo: null,
      serviceTiers: ["*"],
      speeds: ["standard", "unknown"],
      contexts: ["*"],
      rates: standardSonnet,
      sourceUrl: ANTHROPIC_PRICING_SOURCE,
    }),
  );

  return entries;
}

export const PRICING_CATALOG: PricingCatalog = PricingCatalogSchema.parse({
  protocol_version: 2,
  revision: "official-2026-08-10-2",
  published_at: VERIFIED_AT,
  entries: [...openAIEntries(), ...anthropicEntries()],
});

export const PRICING_CATALOG_ETAG = `"${PRICING_CATALOG.revision}"`;
