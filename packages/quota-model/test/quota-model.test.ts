import pricingConformanceJson from "../../protocol/fixtures/pricing-conformance.json" with {
  type: "json",
};
import type {
  BillingChannel,
  DatedUsageRow,
  PricingCatalog,
  PricingCatalogEntry,
} from "@gotry-io/quota-protocol";
import { describe, expect, it } from "vitest";
import {
  aggregateUsageEvents,
  calculateUsageCost,
  calculateUsageRowCost,
  foldPreparedUsageCosts,
  type NormalizedUsageEvent,
  prepareUsageCosts,
  remainingPercent,
  resolvePricingEntry,
  validatePricingCatalog,
} from "../src/index.ts";

type PricingConformanceFixture = {
  catalogs: Record<string, PricingCatalog>;
  rows: Record<string, DatedUsageRow>;
  validation: Array<{
    name: string;
    catalog: string;
    expected: { valid: boolean; issue_codes: string[] };
  }>;
  resolution: Array<{
    name: string;
    catalog: string;
    row: string;
    expected: Record<string, unknown>;
  }>;
  cost: Array<{
    name: string;
    /** `null` states the case where no catalog is available at all. */
    catalog: string | null;
    mode: "calculate" | "auto" | "reported";
    rows: string[];
    expected: Record<string, unknown>;
  }>;
};

const pricingConformance = pricingConformanceJson as PricingConformanceFixture;

describe("pricing conformance", () => {
  it("keeps catalog validation outcomes shared with the native service", () => {
    for (const testCase of pricingConformance.validation) {
      const result = validatePricingCatalog(pricingConformance.catalogs[testCase.catalog]!);
      const actual = result.valid
        ? { valid: true, issue_codes: [] }
        : { valid: false, issue_codes: result.issues.map((issue) => issue.code) };
      expect(actual, testCase.name).toEqual(testCase.expected);
    }
  });

  it("keeps resolution outcomes shared with the native service", () => {
    for (const testCase of pricingConformance.resolution) {
      const result = resolvePricingEntry(
        pricingConformance.catalogs[testCase.catalog]!,
        pricingConformance.rows[testCase.row]!,
      );
      const actual =
        result.status === "priced"
          ? {
              status: result.status,
              entry_id: result.entry.entry_id,
              assumptions: [...result.assumptions],
            }
          : result;
      expect(actual, testCase.name).toEqual(testCase.expected);
    }
  });

  it("keeps cost outcomes shared with the native service", () => {
    for (const testCase of pricingConformance.cost) {
      const rows = testCase.rows.map((name) => pricingConformance.rows[name]!);
      const actual = calculateUsageCost(
        rows,
        testCase.catalog === null ? null : pricingConformance.catalogs[testCase.catalog]!,
        testCase.mode,
      );
      expect(actual, testCase.name).toEqual(testCase.expected);
    }
  });
});

describe("quota calculations", () => {
  it("converts and clamps provider usage", () => {
    expect(remainingPercent(25)).toBe(75);
    expect(remainingPercent(-2)).toBe(100);
    expect(remainingPercent(120)).toBe(0);
  });
});

describe("Usage aggregation", () => {
  it("places every event by the UTC hour it happened in", () => {
    const rows = aggregateUsageEvents([
      event({ occurred_at: "2026-08-02T00:10:00Z", input_tokens: 100 }),
      event({ occurred_at: "2026-08-02T00:20:00Z", input_tokens: 200 }),
      event({ occurred_at: "2026-08-02T01:05:00Z", input_tokens: 400 }),
    ]);

    // The two events inside one UTC hour are one row now: nothing splits them by a local
    // clock the row no longer carries.
    expect(rows.map((row) => row.bucket_start_utc)).toEqual([
      "2026-08-02T00:00:00Z",
      "2026-08-02T01:00:00Z",
    ]);
    expect(rows.map((row) => row.input_tokens)).toEqual([300, 400]);
  });

  it("merges identical dimensions and conserves every token/source-cost subset", () => {
    const rows = aggregateUsageEvents([
      event({
        occurred_at: "2026-08-02T00:01:00Z",
        input_tokens: 1_000,
        cache_read_tokens: 100,
        output_tokens: 200,
        reasoning_tokens: 50,
        source_cost_microusd: 123n,
        source_cost_covered_requests: 1,
      }),
      event({
        occurred_at: "2026-08-02T00:02:00Z",
        input_tokens: 2_000,
        cache_write_5m_tokens: 500,
        output_tokens: 300,
        reasoning_tokens: 75,
        source_cost_microusd: 456n,
        source_cost_covered_requests: 1,
      }),
    ]);

    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      input_tokens: 3_000,
      cache_read_tokens: 100,
      cache_write_5m_tokens: 500,
      output_tokens: 500,
      reasoning_tokens: 125,
      requests: 2,
      source_cost_microusd: "579",
      source_cost_covered_requests: 2,
    });
  });

  it("sorts multiple agents and dimensions deterministically for every input order", () => {
    const events = [
      event({
        agent: "codex",
        model: "gpt-5",
        service_tier: "priority",
      }),
      event({
        agent: "claude_code",
        billing_channel: "anthropic_direct",
        model: "claude-sonnet-4",
      }),
      event({
        agent: "codex",
        model: "gpt-5",
        service_tier: "default",
      }),
    ];

    const forward = aggregateUsageEvents(events);
    const reversed = aggregateUsageEvents([...events].reverse());

    expect(reversed).toEqual(forward);
    expect(forward.map((row) => `${row.agent}:${row.model}:${row.service_tier}`)).toEqual([
      "claude_code:claude-sonnet-4:default",
      "codex:gpt-5:default",
      "codex:gpt-5:priority",
    ]);
  });

  it("rejects invalid instants, token subsets, and safe-integer overflow", () => {
    expect(() => aggregateUsageEvents([event({ occurred_at: "2026-08-02" })])).toThrow();
    expect(() =>
      aggregateUsageEvents([event({ input_tokens: 1, cache_read_tokens: 2 })]),
    ).toThrow();
    expect(() =>
      aggregateUsageEvents([
        event({ input_tokens: Number.MAX_SAFE_INTEGER }),
        event({ occurred_at: "2026-08-02T00:02:00Z", input_tokens: 1 }),
      ]),
    ).toThrow(/safe-integer/);
  });
});

describe("pricing catalog", () => {
  it("accepts an empty catalog", () => {
    expect(validatePricingCatalog(catalog([]))).toMatchObject({ valid: true });
  });

  it("allows an explicit wildcard fallback and selects the more specific entry", () => {
    const priceCatalog = catalog([
      priceEntry({
        entry_id: "fallback",
        service_tier: "*",
        speed: "*",
        inference_geo: "*",
        context_bucket: "*",
        rates: rates({ uncached_input_per_million: "1" }),
      }),
      priceEntry({
        entry_id: "exact",
        rates: rates({ uncached_input_per_million: "2" }),
      }),
    ]);
    expect(validatePricingCatalog(priceCatalog)).toMatchObject({ valid: true });
    expect(calculateUsageCost([usageRow({ input_tokens: 1 })], priceCatalog)).toMatchObject({
      amount_microusd: "2",
      assumptions: ["agent_default_channel"],
    });
  });

  it("never crosses billing channels and supports every bounded priced channel", () => {
    const channels: Exclude<BillingChannel, "unknown">[] = [
      "openai_direct",
      "azure_openai",
      "anthropic_direct",
      "aws_bedrock",
      "google_vertex",
      "openrouter",
    ];
    const entries = channels.map((billingChannel, index) =>
      priceEntry({
        entry_id: `entry_${billingChannel}`,
        billing_channel: billingChannel,
        rates: rates({ uncached_input_per_million: String(index + 1) }),
      }),
    );
    const priceCatalog = catalog(entries);
    expect(validatePricingCatalog(priceCatalog)).toMatchObject({ valid: true });
    expect(
      channels.map(
        (billingChannel) =>
          calculateUsageCost(
            [usageRow({ billing_channel: billingChannel, input_tokens: 1 })],
            priceCatalog,
          ).amount_microusd,
      ),
    ).toEqual(["1", "2", "3", "4", "5", "6"]);
  });
});

describe("Usage cost", () => {
  it("uses exact rational rates and rounds half-up once per stored row", () => {
    const halfRateCatalog = catalog([
      priceEntry({ rates: rates({ uncached_input_per_million: "0.5" }) }),
    ]);
    const cost = calculateUsageCost(
      [
        usageRow({ date: "2026-08-02", input_tokens: 1 }),
        usageRow({ date: "2026-08-03", input_tokens: 1 }),
      ],
      halfRateCatalog,
    );
    expect(cost).toMatchObject({
      status: "complete",
      basis: "calculated",
      amount_microusd: "2",
      calculated_rows: 2,
      unpriced_rows: 0,
    });
  });

  it("prices cache categories, output, and tools without double-counting reasoning", () => {
    const priceCatalog = catalog([
      priceEntry({
        rates: rates({
          uncached_input_per_million: "1.25",
          cache_read_per_million: "0.125",
          cache_write_5m_per_million: "2",
          cache_write_1h_per_million: "4",
          cache_write_inferred_per_million: "3",
          output_per_million: "10",
          web_search_per_request: "0.01",
          web_fetch_per_request: "0.0025",
        }),
      }),
    ]);
    const cost = calculateUsageRowCost(
      priceCatalog,
      usageRow({
        input_tokens: 1_000,
        cache_read_tokens: 100,
        cache_write_5m_tokens: 50,
        cache_write_1h_tokens: 25,
        cache_write_inferred_tokens: 25,
        output_tokens: 200,
        reasoning_tokens: 150,
        web_search_requests: 1,
        web_fetch_requests: 2,
      }),
    );
    expect(cost).toMatchObject({
      status: "priced",
      amount_microusd: 18_288n,
      assumptions: ["cache_write_inferred_rate"],
    });
  });

  it("keeps integers exact above floating-point precision", () => {
    const cost = calculateUsageCost(
      [usageRow({ input_tokens: Number.MAX_SAFE_INTEGER })],
      catalog([priceEntry({ rates: rates({ uncached_input_per_million: "1" }) })]),
    );
    expect(cost.amount_microusd).toBe("9007199254740991");
  });

  it("marks missing prices as unpriced instead of zero", () => {
    const priceCatalog = catalog([priceEntry()]);
    expect(
      calculateUsageCost(
        [usageRow({ cache_write_inferred_tokens: 1, input_tokens: 1 })],
        priceCatalog,
      ),
    ).toMatchObject({
      status: "unavailable",
      unpriced: [{ reason: "missing_rate" }],
    });
  });

  it("uses fully covered reported cost only in the requested modes", () => {
    const reported = usageRow({
      model: "unknown-model",
      source_cost_microusd: "1234",
      source_cost_covered_requests: 1,
    });
    expect(calculateUsageCost([reported], catalog([]), "calculate")).toMatchObject({
      status: "unavailable",
      amount_microusd: null,
    });
    expect(calculateUsageCost([reported], catalog([]), "auto")).toMatchObject({
      status: "complete",
      basis: "reported",
      amount_microusd: "1234",
      assumptions: expect.arrayContaining(["source_reported"]),
    });
    expect(calculateUsageCost([reported], undefined, "reported")).toMatchObject({
      status: "complete",
      basis: "reported",
      amount_microusd: "1234",
      catalog_revision: null,
    });
    expect(
      calculateUsageCost(
        [
          usageRow({
            model: "unknown-model",
            requests: 2,
            source_cost_microusd: "1234",
            source_cost_covered_requests: 1,
          }),
        ],
        catalog([]),
        "auto",
      ),
    ).toMatchObject({ status: "unavailable", amount_microusd: null });
  });

  it("prepares overlapping cost groups once without changing their outcomes", () => {
    const priceCatalog = catalog([priceEntry()]);
    const rows = [
      usageRow({ input_tokens: 1_000_000 }),
      usageRow({
        model: "reported-model",
        source_cost_microusd: "1234",
        source_cost_covered_requests: 1,
      }),
      usageRow({ model: "unpriced-model" }),
    ];
    const prepared = prepareUsageCosts(rows, priceCatalog, "auto");

    expect(foldPreparedUsageCosts(prepared)).toEqual(
      calculateUsageCost(rows, priceCatalog, "auto"),
    );
    expect(foldPreparedUsageCosts(prepared, [0, 2])).toEqual(
      calculateUsageCost(
        [rows[0] as DatedUsageRow, rows[2] as DatedUsageRow],
        priceCatalog,
        "auto",
      ),
    );
    expect(() => foldPreparedUsageCosts(prepared, [3])).toThrow(RangeError);
  });

  it("values an unnamed-channel grok-4.5 row at the xAI official rate", () => {
    const priceCatalog = catalog([
      priceEntry({
        entry_id: "xai_grok_45",
        billing_channel: "xai_direct",
        model: "grok-4.5",
        rates: rates({
          uncached_input_per_million: "2",
          cache_read_per_million: "0.3",
          cache_write_5m_per_million: null,
          cache_write_1h_per_million: null,
          cache_write_inferred_per_million: "2",
          output_per_million: "6",
        }),
      }),
    ]);
    const cost = calculateUsageCost(
      [
        usageRow({
          agent: "grok",
          billing_channel: "unknown",
          channel_source: "unknown",
          model: "grok-4.5",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000,
        }),
      ],
      priceCatalog,
    );
    expect(cost).toMatchObject({
      status: "complete",
      amount_microusd: "8000000",
    });
    expect(cost.assumptions).toContain("vendor_official_price");
    expect(cost.assumptions).not.toContain("agent_default_channel");
    expect(
      resolvePricingEntry(
        priceCatalog,
        usageRow({
          agent: "grok",
          billing_channel: "unknown",
          channel_source: "unknown",
          model: "grok-4.5",
        }),
      ),
    ).toMatchObject({
      status: "priced",
      entry: { entry_id: "xai_grok_45" },
      assumptions: ["vendor_official_price"],
    });
  });

  it("leaves an unnamed-channel row unpriced when two vendor-direct channels match", () => {
    const priceCatalog = catalog([
      priceEntry({
        entry_id: "openai_shared",
        billing_channel: "openai_direct",
        model: "shared-model",
      }),
      priceEntry({
        entry_id: "anthropic_shared",
        billing_channel: "anthropic_direct",
        model: "shared-model",
      }),
    ]);
    expect(
      resolvePricingEntry(
        priceCatalog,
        usageRow({
          billing_channel: "unknown",
          channel_source: "unknown",
          model: "shared-model",
        }),
      ),
    ).toEqual({ status: "unpriced", reason: "unknown_channel" });
  });

  it("reports unknown_model when an unnamed-channel row matches no vendor-direct entry", () => {
    expect(
      resolvePricingEntry(
        catalog([priceEntry()]),
        usageRow({
          billing_channel: "unknown",
          channel_source: "unknown",
          model: "not-cataloged",
        }),
      ),
    ).toEqual({ status: "unpriced", reason: "unknown_model" });
  });

  it("surfaces reviewed wildcard and agent-default assumptions", () => {
    const priceCatalog = catalog([
      priceEntry({
        service_tier: "*",
        speed: "*",
        inference_geo: "*",
        context_bucket: "*",
      }),
    ]);
    expect(
      calculateUsageCost([usageRow({ service_tier: "priority" })], priceCatalog),
    ).toMatchObject({
      status: "complete",
      assumptions: [
        "agent_default_channel",
        "wildcard_context_bucket",
        "wildcard_inference_geo",
        "wildcard_service_tier",
        "wildcard_speed",
      ],
    });
  });
});

function event(overrides: Partial<NormalizedUsageEvent> = {}): NormalizedUsageEvent {
  return {
    occurred_at: "2026-08-02T00:01:00Z",
    agent: "codex",
    model: "gpt-5",
    billing_channel: "openai_direct",
    channel_source: "agent_default",
    input_tokens: 0,
    cache_read_tokens: 0,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 0,
    cache_write_inferred_tokens: 0,
    output_tokens: 0,
    reasoning_tokens: 0,
    requests: 1,
    context_bucket: "le_128k",
    service_tier: "default",
    speed: "standard",
    inference_geo: "global",
    billable_tools: {},
    source_cost_covered_requests: 0,
    ...overrides,
  };
}

function usageRow(overrides: Partial<DatedUsageRow> = {}): DatedUsageRow {
  return {
    date: "2026-08-02",
    agent: "codex",
    billing_channel: "openai_direct",
    channel_source: "agent_default",
    model: "gpt-5",
    context_bucket: "le_128k",
    service_tier: "default",
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

function catalog(entries: PricingCatalogEntry[]): PricingCatalog {
  return {
    protocol_version: 2,
    revision: "pricing_fixture_1",
    published_at: "2026-08-02T00:00:00Z",
    entries,
  };
}

function priceEntry(overrides: Partial<PricingCatalogEntry> = {}): PricingCatalogEntry {
  return {
    entry_id: "openai_gpt_5_default",
    billing_channel: "openai_direct",
    model: "gpt-5",
    aliases: [],
    effective_from: "2026-01-01",
    effective_to: null,
    service_tier: "default",
    speed: "standard",
    inference_geo: "global",
    context_bucket: "le_128k",
    currency: "USD",
    rates: rates(),
    source_url: "https://example.com/pricing",
    verified_at: "2026-08-02T00:00:00Z",
    ...overrides,
  };
}

function rates(overrides: Partial<PricingCatalogEntry["rates"]> = {}) {
  return {
    uncached_input_per_million: "1",
    cache_read_per_million: "0.1",
    cache_write_5m_per_million: "1.25",
    cache_write_1h_per_million: "2",
    cache_write_inferred_per_million: null,
    output_per_million: "10",
    web_search_per_request: null,
    web_fetch_per_request: null,
    ...overrides,
  };
}
