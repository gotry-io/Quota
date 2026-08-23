import {
  type PricedBillingChannel,
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
 * - https://raw.githubusercontent.com/anomalyco/models.dev/dev/providers/openai/models/gpt-5.1.toml
 * - https://raw.githubusercontent.com/anomalyco/models.dev/dev/providers/openai/models/gpt-5.2.toml
 * - https://raw.githubusercontent.com/anomalyco/models.dev/dev/providers/openai/models/gpt-5.6-terra.toml
 * - https://raw.githubusercontent.com/anomalyco/models.dev/dev/providers/anthropic/models/claude-opus-5.toml
 * - https://raw.githubusercontent.com/anomalyco/models.dev/dev/providers/anthropic/models/claude-sonnet-5.toml
 * - https://raw.githubusercontent.com/anomalyco/models.dev/dev/providers/anthropic/models/claude-fable-5.toml
 * - https://raw.githubusercontent.com/anomalyco/models.dev/dev/providers/xai/models/grok-4.6.toml
 *
 * The source repository is available at https://github.com/anomalyco/models.dev
 * and its license is https://github.com/anomalyco/models.dev/blob/dev/LICENSE.
 *
 * `verified_at` is per entry: entries keep the date their rates were last
 * checked against the cited page, so adding a model never restates when the
 * existing rates were verified.
 */

const VERIFIED_AT = "2026-08-10T00:00:00.000Z";
const VERIFIED_AT_2026_08_23 = "2026-08-23T00:00:00.000Z";
const OPENAI_PRICING_SOURCE = "https://developers.openai.com/api/docs/pricing";
const OPENAI_CODEX_52_SOURCE = "https://developers.openai.com/api/docs/models/gpt-5.2-codex";
const OPENAI_CODEX_53_SOURCE = "https://developers.openai.com/api/docs/models/gpt-5.3-codex";
const OPENAI_GPT_54_SOURCE = "https://developers.openai.com/api/docs/models/gpt-5.4";
const OPENAI_GPT_55_SOURCE = "https://developers.openai.com/api/docs/models/gpt-5.5";
const OPENAI_SOL_SOURCE = "https://developers.openai.com/api/docs/models/gpt-5.6-sol";
const OPENAI_LUNA_SOURCE = "https://developers.openai.com/api/docs/models/gpt-5.6-luna";
const OPENAI_56_PRICE_CHANGE_SOURCE =
  "https://openai.com/index/advancing-the-price-performance-frontier-with-gpt-5-6/";
const XAI_GROK_45_SOURCE = "https://docs.x.ai/developers/models/grok-4.5";
const XAI_GROK_46_SOURCE = "https://docs.x.ai/developers/models/grok-4.6";
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
  billingChannel?: PricedBillingChannel;
  aliases?: readonly string[];
  effectiveFrom: string;
  effectiveTo: string | null;
  serviceTiers: readonly string[];
  speeds: readonly string[];
  inferenceGeos: readonly string[];
  contexts: readonly (ContextBucket | "*")[];
  rates: PricingRates | ((context: ContextBucket | "*") => PricingRates);
  sourceUrl: string;
  verifiedAt?: string;
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
            billing_channel:
              input.billingChannel ??
              (input.model.startsWith("claude-") ? "anthropic_direct" : "openai_direct"),
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
            verified_at: input.verifiedAt ?? VERIFIED_AT,
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

  // These models each publish one documented API rate independent of context
  // length.  No separate service/speed/geo/context rates are published, so
  // one explicit wildcard entry is the closest documented approximation.
  // Codex's parser reports an inferred cache-write bucket; use the uncached
  // input rate for that bucket as an explicit approximation, while retaining
  // null for the undocumented 5m/1h cache-write buckets.  The GPT-5.1/5.2
  // release dates come from the models.dev TOMLs cited in the file header.
  const flatRate = (input: string, cacheRead: string, output: string) =>
    openAIStandardRates(input, cacheRead, null, output, input);
  for (const model of [
    {
      model: "gpt-5.2-codex",
      effectiveFrom: "2025-12-11",
      sourceUrl: OPENAI_CODEX_52_SOURCE,
      rates: flatRate("1.75", "0.175", "14"),
    },
    {
      model: "gpt-5.3-codex",
      effectiveFrom: "2026-02-05",
      sourceUrl: OPENAI_CODEX_53_SOURCE,
      rates: flatRate("1.75", "0.175", "14"),
    },
    {
      model: "gpt-5.1",
      effectiveFrom: "2025-11-13",
      sourceUrl: OPENAI_PRICING_SOURCE,
      rates: flatRate("1.25", "0.125", "10"),
      verifiedAt: VERIFIED_AT_2026_08_23,
    },
    {
      model: "gpt-5.2",
      effectiveFrom: "2025-12-11",
      sourceUrl: OPENAI_PRICING_SOURCE,
      rates: flatRate("1.75", "0.175", "14"),
      verifiedAt: VERIFIED_AT_2026_08_23,
    },
  ]) {
    entries.push(
      ...expandEntries({
        entryPrefix: `openai-${model.model}`,
        model: model.model,
        effectiveFrom: model.effectiveFrom,
        effectiveTo: null,
        serviceTiers: ["*"],
        speeds: ["*"],
        inferenceGeos: ["*"],
        contexts: ["*"],
        rates: model.rates,
        sourceUrl: model.sourceUrl,
        ...(model.verifiedAt ? { verifiedAt: model.verifiedAt } : {}),
      }),
    );
  }

  for (const model of [
    {
      model: "gpt-5.4",
      effectiveFrom: "2026-03-05",
      sourceUrl: OPENAI_GPT_54_SOURCE,
      prefix: "openai-gpt-5.4",
      rates: (context: ContextBucket | "*") =>
        context === "gt_272k"
          ? openAIStandardRates("5", "0.5", null, "22.5", null)
          : openAIStandardRates("2.5", "0.25", null, "15", null),
      fastRates: openAIStandardRates("5", "0.5", null, "30", null),
    },
    {
      model: "gpt-5.5",
      effectiveFrom: "2026-04-24",
      sourceUrl: OPENAI_GPT_55_SOURCE,
      prefix: "openai-gpt-5.5",
      rates: (context: ContextBucket | "*") =>
        context === "gt_272k"
          ? openAIStandardRates("10", "1", null, "45", null)
          : openAIStandardRates("5", "0.5", null, "30", null),
      fastRates: openAIStandardRates("12.5", "1.25", null, "75", null),
    },
  ]) {
    entries.push(
      ...expandEntries({
        entryPrefix: `${model.prefix}-standard`,
        model: model.model,
        effectiveFrom: model.effectiveFrom,
        effectiveTo: null,
        serviceTiers: STANDARD_SERVICE_TIERS,
        speeds: STANDARD_SPEEDS,
        inferenceGeos: ["*"],
        contexts: SHORT_AND_LONG_CONTEXTS,
        rates: model.rates,
        sourceUrl: model.sourceUrl,
      }),
      ...expandEntries({
        entryPrefix: `${model.prefix}-fast`,
        model: model.model,
        effectiveFrom: model.effectiveFrom,
        effectiveTo: null,
        serviceTiers: ["priority"],
        speeds: ["fast"],
        inferenceGeos: ["*"],
        contexts: CONTEXT_BUCKETS.slice(0, -1),
        rates: model.fastRates,
        sourceUrl: OPENAI_PRICING_SOURCE,
      }),
    );
  }

  // OpenAI's GPT-5.6 family prices one short and one long tier, with the long
  // tier beginning after the 272k billable-input cap.  Each rate array is
  // [uncached input, cache read, cache write, output].
  const shortLongRates =
    (short: readonly string[], long: readonly string[]) => (context: ContextBucket | "*") => {
      const [input = "0", cacheRead = "0", cacheWrite = "0", output = "0"] =
        context === "gt_272k" ? long : short;
      return openAIStandardRates(input, cacheRead, cacheWrite, output);
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
      rates: shortLongRates(["5", "0.5", "6.25", "30"], ["10", "1", "12.5", "45"]),
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
      rates: shortLongRates(["10", "1", "12.5", "60"], ["20", "2", "25", "90"]),
      sourceUrl: OPENAI_PRICING_SOURCE,
    }),
  );

  entries.push(
    ...expandEntries({
      entryPrefix: "openai-gpt-5.6-luna-launch",
      model: "gpt-5.6-luna",
      effectiveFrom: "2026-07-09",
      effectiveTo: "2026-07-30",
      serviceTiers: STANDARD_SERVICE_TIERS,
      speeds: STANDARD_SPEEDS,
      inferenceGeos: ["*"],
      contexts: SHORT_AND_LONG_CONTEXTS,
      rates: shortLongRates(["1", "0.1", "1.25", "6"], ["2", "0.2", "2.5", "9"]),
      sourceUrl: OPENAI_LUNA_SOURCE,
    }),
    ...expandEntries({
      entryPrefix: "openai-gpt-5.6-luna-standard",
      model: "gpt-5.6-luna",
      effectiveFrom: "2026-07-30",
      effectiveTo: null,
      serviceTiers: STANDARD_SERVICE_TIERS,
      speeds: STANDARD_SPEEDS,
      inferenceGeos: ["*"],
      contexts: SHORT_AND_LONG_CONTEXTS,
      rates: shortLongRates(["0.2", "0.02", "0.25", "1.2"], ["0.4", "0.04", "0.5", "1.8"]),
      sourceUrl: OPENAI_56_PRICE_CHANGE_SOURCE,
    }),
    ...expandEntries({
      entryPrefix: "openai-gpt-5.6-luna-fast",
      model: "gpt-5.6-luna",
      effectiveFrom: "2026-07-30",
      effectiveTo: null,
      serviceTiers: ["priority"],
      speeds: ["fast"],
      inferenceGeos: ["*"],
      contexts: SHORT_AND_LONG_CONTEXTS,
      rates: shortLongRates(["0.4", "0.04", "0.5", "2.4"], ["0.8", "0.08", "1", "3.6"]),
      sourceUrl: OPENAI_PRICING_SOURCE,
    }),
  );

  // GPT-5.6 Terra shares Luna's 2026-07-30 price change.  Only the post-change
  // rates are published, so Terra starts at that date and rows before it stay
  // outside the effective range instead of being priced from a guessed launch
  // rate.  The fast tier documents one rate with no long-context counterpart,
  // so it covers the short buckets only.
  entries.push(
    ...expandEntries({
      entryPrefix: "openai-gpt-5.6-terra-standard",
      model: "gpt-5.6-terra",
      effectiveFrom: "2026-07-30",
      effectiveTo: null,
      serviceTiers: STANDARD_SERVICE_TIERS,
      speeds: STANDARD_SPEEDS,
      inferenceGeos: ["*"],
      contexts: SHORT_AND_LONG_CONTEXTS,
      rates: shortLongRates(["2", "0.2", "2.5", "12"], ["4", "0.4", "5", "18"]),
      sourceUrl: OPENAI_56_PRICE_CHANGE_SOURCE,
      verifiedAt: VERIFIED_AT_2026_08_23,
    }),
    ...expandEntries({
      entryPrefix: "openai-gpt-5.6-terra-fast",
      model: "gpt-5.6-terra",
      effectiveFrom: "2026-07-30",
      effectiveTo: null,
      serviceTiers: ["priority"],
      speeds: ["fast"],
      inferenceGeos: ["*"],
      contexts: CONTEXT_BUCKETS.slice(0, -1),
      rates: openAIStandardRates("4", "0.4", "5", "24"),
      sourceUrl: OPENAI_PRICING_SOURCE,
      verifiedAt: VERIFIED_AT_2026_08_23,
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

  // The Claude 5 generation includes the full 1M context window at standard
  // pricing, so each model needs one context-independent entry.  Launch dates
  // come from the Claude Platform release notes: Fable 5 on 2026-06-09,
  // Sonnet 5 on 2026-06-30, Opus 5 on 2026-07-24.  Sonnet 5's launch price of
  // $2/$10 became the standard price on 2026-08-10 and the scheduled increase
  // was cancelled, so one entry covers its whole life.
  // Opus 5 fast mode is billed at $10/$50 across the full context window, with
  // the prompt-caching multipliers applied on top of the fast input rate.
  // Fable 5 and Sonnet 5 do not offer fast mode, so they get no fast rates.
  for (const model of [
    {
      model: "claude-fable-5",
      effectiveFrom: "2026-06-09",
      rates: anthropicRates("10", "1", "12.5", "20", "50"),
      fastRates: null,
    },
    {
      model: "claude-sonnet-5",
      effectiveFrom: "2026-06-30",
      rates: anthropicRates("2", "0.2", "2.5", "4", "10"),
      fastRates: null,
    },
    {
      model: "claude-opus-5",
      effectiveFrom: "2026-07-24",
      rates: standardOpus,
      fastRates: anthropicRates("10", "1", "12.5", "20", "50"),
    },
  ]) {
    const shared = {
      model: model.model,
      effectiveFrom: model.effectiveFrom,
      effectiveTo: null,
      serviceTiers: ["*"],
      contexts: ["*"],
      sourceUrl: ANTHROPIC_PRICING_SOURCE,
      verifiedAt: VERIFIED_AT_2026_08_23,
    } as const;
    entries.push(
      ...expandAnthropicWithUs({
        ...shared,
        entryPrefix: `anthropic-${model.model}-standard`,
        speeds: ["standard", "unknown"],
        rates: model.rates,
      }),
      ...(model.fastRates
        ? expandAnthropicWithUs({
            ...shared,
            entryPrefix: `anthropic-${model.model}-fast`,
            speeds: ["fast"],
            rates: model.fastRates,
          })
        : []),
    );
  }

  return entries;
}

function xaiEntries(): PricingCatalogEntry[] {
  // xAI bills a request that reaches 200k prompt tokens at the long rate for
  // every token in the request, so the long tier starts at the 200k bucket.
  const isLongContext = (context: ContextBucket | "*") =>
    context === "gt_200k_le_256k" || context === "gt_256k_le_272k" || context === "gt_272k";
  const grokRates =
    (shortCacheRead: string, longCacheRead: string) => (context: ContextBucket | "*") => {
      const long = isLongContext(context);
      return tokenRates(
        long ? "4" : "2",
        long ? longCacheRead : shortCacheRead,
        null,
        null,
        long ? "12" : "6",
        false,
        long ? "4" : "2",
      );
    };
  const grokContexts = ["*", "gt_200k_le_256k", "gt_256k_le_272k", "gt_272k"] as const;
  return [
    ...expandEntries({
      entryPrefix: "xai-grok-4.5-standard",
      model: "grok-4.5",
      billingChannel: "xai_direct",
      aliases: ["grok-4.5-latest"],
      effectiveFrom: "2026-07-08",
      effectiveTo: null,
      serviceTiers: ["standard", "unknown"],
      speeds: ["standard", "unknown"],
      inferenceGeos: ["*"],
      contexts: grokContexts,
      rates: grokRates("0.3", "0.6"),
      sourceUrl: XAI_GROK_45_SOURCE,
    }),
    // Grok 4.6 launched on 2026-08-12 with the same token rates as Grok 4.5
    // and a higher cached-input rate.
    ...expandEntries({
      entryPrefix: "xai-grok-4.6-standard",
      model: "grok-4.6",
      billingChannel: "xai_direct",
      effectiveFrom: "2026-08-12",
      effectiveTo: null,
      serviceTiers: ["standard", "unknown"],
      speeds: ["standard", "unknown"],
      inferenceGeos: ["*"],
      contexts: grokContexts,
      rates: grokRates("0.5", "1"),
      sourceUrl: XAI_GROK_46_SOURCE,
      verifiedAt: VERIFIED_AT_2026_08_23,
    }),
  ];
}

export const PRICING_CATALOG: PricingCatalog = PricingCatalogSchema.parse({
  protocol_version: 2,
  revision: "official-2026-08-23-1",
  published_at: VERIFIED_AT_2026_08_23,
  entries: [...openAIEntries(), ...anthropicEntries(), ...xaiEntries()],
});

export const PRICING_CATALOG_ETAG = `"${PRICING_CATALOG.revision}"`;
