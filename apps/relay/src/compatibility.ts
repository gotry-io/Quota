import {
  BILLING_AGENTS,
  type BillingAgent,
  type PricingCatalog,
  PricingCatalogSchema,
} from "@gotry-io/quota-protocol";

/**
 * Compatibility retained for released QuotaCLI 0.0.5 clients through QuotaBar 0.0.7.
 *
 * New clients explicitly request all agents. The query-less request and its reduced pricing
 * catalog stay together here so the release boundary is not spread across route handlers.
 */
const RELEASED_USAGE_AGENTS = ["codex", "claude_code"] as const satisfies readonly BillingAgent[];
const RELEASED_USAGE_RANGE_DAYS = 366;

export interface PricingCatalogVariants {
  current: { catalog: PricingCatalog; etag: string };
  released: { catalog: PricingCatalog; etag: string };
}

export function pricingCatalogVariants(
  catalog: PricingCatalog,
  etag: string,
): PricingCatalogVariants {
  const releasedCatalog = PricingCatalogSchema.parse({
    ...catalog,
    revision: `${catalog.revision}-legacy`,
    entries: catalog.entries.filter((entry) => entry.billing_channel !== "xai_direct"),
  });
  return {
    current: { catalog, etag },
    released: { catalog: releasedCatalog, etag: `"${releasedCatalog.revision}"` },
  };
}

export function usageAgentsForRequest(
  requested: string | undefined,
): readonly BillingAgent[] | undefined {
  return requested === undefined
    ? RELEASED_USAGE_AGENTS
    : requested === "all"
      ? BILLING_AGENTS
      : undefined;
}

export function pricingCatalogForRequest(
  variants: PricingCatalogVariants,
  requested: string | undefined,
): { catalog: PricingCatalog; etag: string } | undefined {
  return requested === undefined
    ? variants.released
    : requested === "all"
      ? variants.current
      : undefined;
}

export function releasedUsageRangeExceeded(
  requested: string | undefined,
  from: string,
  to: string,
): boolean {
  if (requested !== undefined) return false;
  return (
    (Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000 >=
    RELEASED_USAGE_RANGE_DAYS
  );
}
