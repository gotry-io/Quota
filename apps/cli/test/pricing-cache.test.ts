import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { PricingCatalog } from "@gotry-io/quota-protocol";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  loadPricingCatalogCache,
  refreshPricingCatalogCache,
} from "../src/account/pricing-cache.ts";
import { AccountStateStore } from "../src/account/state.ts";

let temporaryDirectory: string;

beforeEach(async () => {
  temporaryDirectory = await mkdtemp(join(tmpdir(), "quotacli-pricing-cache-"));
});

afterEach(async () => {
  await rm(temporaryDirectory, { recursive: true, force: true });
});

describe("pricing catalog cache", () => {
  it("atomically caches a validated catalog and revalidates a 304 cache hit", async () => {
    const store = new AccountStateStore({ root: temporaryDirectory });
    const client = {
      pricingCatalog: vi
        .fn()
        .mockResolvedValueOnce({ status: "updated", etag: '"pricing-test"', catalog: catalog() })
        .mockResolvedValueOnce({ status: "not_modified", etag: '"pricing-test"' }),
    };

    await expect(
      refreshPricingCatalogCache(store, client, new Date("2026-08-10T00:00:00Z")),
    ).resolves.toMatchObject({ etag: '"pricing-test"', catalog: { revision: "pricing-test" } });
    await expect(
      refreshPricingCatalogCache(store, client, new Date("2026-08-10T01:00:00Z")),
    ).resolves.toMatchObject({ cached_at: "2026-08-10T00:00:00.000Z" });
    expect(client.pricingCatalog).toHaveBeenNthCalledWith(2, '"pricing-test"');
  });

  it("rejects an ambiguous download without replacing the last valid cache", async () => {
    const store = new AccountStateStore({ root: temporaryDirectory });
    await refreshPricingCatalogCache(store, {
      pricingCatalog: vi.fn(async () => ({
        status: "updated" as const,
        etag: null,
        catalog: catalog(),
      })),
    });
    const ambiguous = catalog();
    const [baseEntry] = ambiguous.entries;
    if (!baseEntry) throw new Error("Missing pricing fixture.");
    ambiguous.entries.push({ ...baseEntry, entry_id: "duplicate-price" });

    await expect(
      refreshPricingCatalogCache(store, {
        pricingCatalog: vi.fn(async () => ({
          status: "updated" as const,
          etag: null,
          catalog: ambiguous,
        })),
      }),
    ).rejects.toThrow("pricing catalog cache");
    await expect(loadPricingCatalogCache(store)).resolves.toMatchObject({
      catalog: { revision: "pricing-test", entries: [{ entry_id: "test-price" }] },
    });
  });
});

function catalog(): PricingCatalog {
  return {
    protocol_version: 2,
    revision: "pricing-test",
    published_at: "2026-08-10T00:00:00Z",
    entries: [
      {
        entry_id: "test-price",
        billing_channel: "openai_direct",
        model: "test-model",
        aliases: [],
        effective_from: "2026-08-10",
        effective_to: null,
        service_tier: "standard",
        speed: "standard",
        inference_geo: "global",
        context_bucket: "le_128k",
        currency: "USD",
        rates: {
          uncached_input_per_million: "1",
          cache_read_per_million: null,
          cache_write_5m_per_million: null,
          cache_write_1h_per_million: null,
          cache_write_inferred_per_million: null,
          output_per_million: "2",
          web_search_per_request: null,
          web_fetch_per_request: null,
        },
        source_url: "https://example.test/pricing",
        verified_at: "2026-08-10T00:00:00Z",
      },
    ],
  };
}
