import {
  AccountUsageSummarySchema,
  MAXIMUM_USAGE_BREAKDOWNS,
  type AccountUsageSummary,
  type PricingCatalog,
  type UsageBreakdownDimension,
  type UsageCostMode,
  type UsageCostOutcome,
  type UsageHourlyFact,
  type UsageTokenTotals,
  UsageTokenTotalsSchema,
} from "@gotry-io/quota-protocol";
import {
  calculateUsageCost,
  foldPreparedUsageCosts,
  prepareUsageCosts,
} from "@gotry-io/quota-model";
import type {
  StoredUsageCoverage,
  StoredUsageHourlyFact,
  UsageQueryResult,
} from "@gotry-io/relay-core";

const breakdownDimensions = [
  "device",
  "agent",
  "model",
  "billing_channel",
  "usage_date",
  "bucket_start_utc",
] as const satisfies readonly UsageBreakdownDimension[];

export function buildUsageSummary(
  result: UsageQueryResult,
  range: { from: string; to: string },
  mode: UsageCostMode,
  catalog: PricingCatalog,
): AccountUsageSummary {
  const facts = result.rows.map(usageFact);
  const preparedCosts = prepareUsageCosts(facts, catalog, mode);
  const totals = emptyTotals();
  const groups = new Map<string, UsageSummaryGroup>();
  for (const [index, row] of result.rows.entries()) {
    const fact = facts[index];
    if (!fact) throw new UsageSummaryLimitError();
    addTotals(totals, fact);
    for (const dimension of breakdownDimensions) {
      addGroup(groups, dimension, breakdownKey(row, dimension), fact, index);
    }
  }
  if (groups.size > MAXIMUM_USAGE_BREAKDOWNS) {
    throw new UsageSummaryLimitError();
  }
  const breakdowns = [...groups]
    .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0))
    .map(([compoundKey, group]) => {
      const separator = compoundKey.indexOf(":");
      return {
        dimension: compoundKey.slice(0, separator),
        key: compoundKey.slice(separator + 1),
        totals: serializedTotals(group.totals),
        cost: foldPreparedUsageCosts(preparedCosts, group.rowIndexes),
      };
    });
  return boundedModelResult(() =>
    AccountUsageSummarySchema.parse({
      range,
      totals: serializedTotals(totals),
      cost: foldPreparedUsageCosts(preparedCosts),
      coverage: result.coverage.map(coverageSummary),
      breakdowns,
    }),
  );
}

export function buildUsageCost(
  rows: readonly StoredUsageHourlyFact[],
  mode: UsageCostMode,
  catalog: PricingCatalog,
): UsageCostOutcome {
  return boundedModelResult(() => calculateUsageCost(rows.map(usageFact), catalog, mode));
}

export class UsageSummaryLimitError extends Error {
  constructor() {
    super("Usage summary exceeds the response limit");
    this.name = "UsageSummaryLimitError";
  }
}

function usageFact(row: StoredUsageHourlyFact) {
  const { device_id: _deviceID, aggregation_timezone: _aggregationTimezone, ...fact } = row;
  return fact;
}

function coverageSummary(item: StoredUsageCoverage) {
  return {
    device_id: item.device_id,
    agent: item.agent,
    start_at: item.start_at,
    end_at: item.end_at,
    status: item.status,
  };
}

function breakdownKey(
  row: StoredUsageHourlyFact,
  dimension: (typeof breakdownDimensions)[number],
): string {
  switch (dimension) {
    case "device":
      return row.device_id;
    case "agent":
      return row.agent;
    case "model":
      return row.model;
    case "billing_channel":
      return row.billing_channel;
    case "usage_date":
      return row.usage_date;
    case "bucket_start_utc":
      return row.bucket_start_utc;
  }
}

function addGroup(
  groups: Map<string, UsageSummaryGroup>,
  dimension: UsageBreakdownDimension,
  key: string,
  row: UsageHourlyFact,
  rowIndex: number,
): void {
  const compound = `${dimension}:${key}`;
  let group = groups.get(compound);
  if (!group) {
    group = { totals: emptyTotals(), rowIndexes: [] };
    groups.set(compound, group);
  }
  addTotals(group.totals, row);
  group.rowIndexes.push(rowIndex);
}

interface UsageSummaryGroup {
  totals: MutableUsageTotals;
  rowIndexes: number[];
}

type MutableUsageTotals = Omit<UsageTokenTotals, "source_cost_microusd"> & {
  source_cost_microusd: bigint;
};

const countKeys = [
  "input_tokens",
  "cache_read_tokens",
  "cache_write_5m_tokens",
  "cache_write_1h_tokens",
  "cache_write_inferred_tokens",
  "output_tokens",
  "reasoning_tokens",
  "requests",
  "web_search_requests",
  "web_fetch_requests",
  "source_cost_covered_requests",
] as const;

function emptyTotals(): MutableUsageTotals {
  return {
    input_tokens: 0,
    cache_read_tokens: 0,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 0,
    cache_write_inferred_tokens: 0,
    output_tokens: 0,
    reasoning_tokens: 0,
    requests: 0,
    web_search_requests: 0,
    web_fetch_requests: 0,
    source_cost_microusd: 0n,
    source_cost_covered_requests: 0,
  };
}

function addTotals(target: MutableUsageTotals, row: UsageHourlyFact): void {
  for (const key of countKeys) {
    const total = target[key] + row[key];
    if (!Number.isSafeInteger(total)) throw new UsageSummaryLimitError();
    target[key] = total;
  }
  target.source_cost_microusd += BigInt(row.source_cost_microusd ?? "0");
}

function serializedTotals(totals: MutableUsageTotals): UsageTokenTotals {
  return boundedModelResult(() =>
    UsageTokenTotalsSchema.parse({
      ...totals,
      source_cost_microusd:
        totals.source_cost_covered_requests === 0 ? null : totals.source_cost_microusd.toString(),
    }),
  );
}

function boundedModelResult<Result>(operation: () => Result): Result {
  try {
    return operation();
  } catch {
    throw new UsageSummaryLimitError();
  }
}
