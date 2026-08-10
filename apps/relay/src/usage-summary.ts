import {
  AccountUsageSummarySchema,
  MAXIMUM_USAGE_BREAKDOWNS,
  type AccountUsageSummary,
  type PricingCatalog,
  type UsageBreakdownDimension,
  type UsageCostMode,
  type UsageCostOutcome,
  type UsageTokenTotals,
} from "@gotry-io/quota-protocol";
import { calculateUsageCost, foldUsageFacts } from "@gotry-io/quota-model";
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
  const groups = new Map<string, StoredUsageHourlyFact[]>();
  for (const row of result.rows) {
    for (const dimension of breakdownDimensions) {
      addGroup(groups, dimension, breakdownKey(row, dimension), row);
    }
  }
  if (groups.size > MAXIMUM_USAGE_BREAKDOWNS) {
    throw new UsageSummaryLimitError();
  }
  const breakdowns = [...groups]
    .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0))
    .map(([compoundKey, rows]) => {
      const separator = compoundKey.indexOf(":");
      return {
        dimension: compoundKey.slice(0, separator),
        key: compoundKey.slice(separator + 1),
        totals: usageTotals(rows),
        cost: usageCost(rows, mode, catalog),
      };
    });
  return boundedModelResult(() =>
    AccountUsageSummarySchema.parse({
      range,
      totals: usageTotals(result.rows),
      cost: usageCost(result.rows, mode, catalog),
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
  return usageCost(rows, mode, catalog);
}

export class UsageSummaryLimitError extends Error {
  constructor() {
    super("Usage summary exceeds the response limit");
    this.name = "UsageSummaryLimitError";
  }
}

function usageTotals(rows: readonly StoredUsageHourlyFact[]): UsageTokenTotals {
  return boundedModelResult(() => foldUsageFacts(rows.map(usageFact)));
}

function usageCost(
  rows: readonly StoredUsageHourlyFact[],
  mode: UsageCostMode,
  catalog: PricingCatalog,
): UsageCostOutcome {
  return boundedModelResult(() => calculateUsageCost(rows.map(usageFact), catalog, mode));
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
    status: "complete" as const,
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
  groups: Map<string, StoredUsageHourlyFact[]>,
  dimension: UsageBreakdownDimension,
  key: string,
  row: StoredUsageHourlyFact,
): void {
  const compound = `${dimension}:${key}`;
  const group = groups.get(compound);
  if (group) {
    group.push(row);
  } else {
    groups.set(compound, [row]);
  }
}

function boundedModelResult<Result>(operation: () => Result): Result {
  try {
    return operation();
  } catch {
    throw new UsageSummaryLimitError();
  }
}
