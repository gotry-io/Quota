/**
 * The Usage numbers this page derives rather than reads.
 *
 * The cache hit rate is stated once per runtime and answered against
 * `packages/protocol/fixtures/usage-metrics-conformance.json`, so this file calls the shared rule
 * rather than restating it. See ADR 0036.
 *
 * These take the fields they read rather than a whole contract type, because a reader may be
 * shown a member this build has never heard of. See ADR 0023.
 */
import { usageCacheHitBasisPoints } from "@gotry-io/quota-model";
import { WEB_LOCALE } from "./format.ts";

type TotalsView = {
  total_tokens: number;
  input_tokens: number;
  output_tokens: number;
  cache_read_input_tokens: number;
  cache_write_input_tokens: number;
  reasoning_tokens: number;
  messages: number;
};

type CostPricedView = {
  status: string;
  calculated_rows?: number;
  reported_rows?: number;
  unpriced_rows?: number;
};

/**
 * How much of this period's Usage the catalog priced.
 *
 * `Priced N of M rows` when the cost outcome names both counts. Otherwise the status line:
 * every row, or how many this catalog skipped.
 */
export function costPricedLabel(cost: CostPricedView): string {
  const calculated = cost.calculated_rows;
  const reported = cost.reported_rows;
  const unpriced = cost.unpriced_rows;
  if (
    typeof calculated === "number" &&
    typeof reported === "number" &&
    typeof unpriced === "number"
  ) {
    const priced = calculated + reported;
    return `Priced ${new Intl.NumberFormat(WEB_LOCALE).format(priced)} of ${new Intl.NumberFormat(WEB_LOCALE).format(priced + unpriced)} rows`;
  }
  if (cost.status === "complete") return "Cost covers every row";
  const skipped = typeof unpriced === "number" ? unpriced : 0;
  return `Cost skips ${new Intl.NumberFormat(WEB_LOCALE).format(skipped)} rows this catalog can't price`;
}

/** How much of a period's input came back from a cache, as whole percent, or `null` for no input. */
export function cacheHitLabel(totals: TotalsView): string | null {
  const basisPoints = usageCacheHitBasisPoints(totals);
  if (basisPoints === null) return null;
  return `${new Intl.NumberFormat(WEB_LOCALE).format(Math.round(basisPoints / 100))}%`;
}
