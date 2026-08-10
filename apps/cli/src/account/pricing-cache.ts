import { validatePricingCatalog } from "@gotry-io/quota-model";
import type { PricingCatalog } from "@gotry-io/quota-protocol";
import { PricingCatalogSchema, Rfc3339InstantSchema } from "@gotry-io/quota-protocol";
import { z } from "zod";
import type { AccountClient } from "./client.ts";
import { type AccountStateStore, AccountStateStoreError } from "./state.ts";

const PRICING_CACHE_SCHEMA_VERSION = 1 as const;

export interface PricingCatalogCache {
  schema_version: typeof PRICING_CACHE_SCHEMA_VERSION;
  etag: string | null;
  cached_at: string;
  catalog: PricingCatalog;
}

const PricingCatalogCacheSchema = z
  .object({
    schema_version: z.literal(PRICING_CACHE_SCHEMA_VERSION),
    etag: z
      .string()
      .max(256)
      .refine((value) => value.trim() === value)
      .nullable(),
    cached_at: Rfc3339InstantSchema.refine(isCanonicalInstant),
    catalog: PricingCatalogSchema,
  })
  .strict();

export async function loadPricingCatalogCache(
  store: AccountStateStore,
): Promise<PricingCatalogCache | null> {
  const value = await store.loadArtifact("pricing-catalog.json");
  return value === null ? null : decodePricingCatalogCache(value);
}

export async function refreshPricingCatalogCache(
  store: AccountStateStore,
  client: Pick<AccountClient, "pricingCatalog">,
  now = new Date(),
): Promise<PricingCatalogCache> {
  const current = await loadPricingCatalogCache(store);
  const result = await client.pricingCatalog(current?.etag ?? undefined);
  if (result.status === "not_modified") {
    if (current === null) {
      throw new AccountStateStoreError(
        "invalid_state",
        "Quota returned 304 without a cached catalog.",
      );
    }
    return current;
  }
  const validated = validatePricingCatalog(result.catalog);
  if (!validated.valid) throw invalidCache();
  const next = {
    schema_version: PRICING_CACHE_SCHEMA_VERSION,
    etag: result.etag,
    cached_at: now.toISOString(),
    catalog: validated.catalog,
  } satisfies PricingCatalogCache;
  await store.saveArtifact("pricing-catalog.json", next);
  return next;
}

export function decodePricingCatalogCache(value: unknown): PricingCatalogCache {
  if (
    typeof value === "object" &&
    value !== null &&
    "schema_version" in value &&
    typeof value.schema_version === "number" &&
    Number.isSafeInteger(value.schema_version) &&
    value.schema_version > PRICING_CACHE_SCHEMA_VERSION
  ) {
    throw new AccountStateStoreError(
      "client_upgrade_required",
      "The pricing cache was written by a newer QuotaCLI.",
    );
  }
  const parsed = PricingCatalogCacheSchema.safeParse(value);
  if (!parsed.success) throw invalidCache();
  const validated = validatePricingCatalog(parsed.data.catalog);
  if (!validated.valid) throw invalidCache();
  return {
    schema_version: PRICING_CACHE_SCHEMA_VERSION,
    etag: parsed.data.etag,
    cached_at: parsed.data.cached_at,
    catalog: validated.catalog,
  };
}

function invalidCache(): AccountStateStoreError {
  return new AccountStateStoreError("invalid_state", "The local pricing catalog cache is invalid.");
}

function isCanonicalInstant(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) return false;
  const canonical = new Date(timestamp).toISOString();
  return value === canonical || value === canonical.replace(".000Z", "Z");
}
