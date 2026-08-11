import {
  AccountUsageSummarySchema,
  MAXIMUM_USAGE_BREAKDOWNS,
  MAXIMUM_UNPRICED_ITEMS,
  type AccountUsageSummary,
  type PricingCatalog,
  type UsageBreakdownDimension,
  type UsageCostMode,
  type UsageCostOutcome,
  type UsageHourlyFact,
  type UsageTokenTotals,
  type UsageUnpricedItem,
  UsageCostOutcomeSchema,
  UsageTokenTotalsSchema,
} from "@gotry-io/quota-protocol";
import {
  foldPreparedUsageCosts,
  type PreparedUsageCosts,
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
  includeHourlyBreakdowns = true,
  includeTruncationFields = true,
): AccountUsageSummary {
  const facts = result.rows.map(usageFact);
  const preparedCosts = prepareUsageCosts(facts, catalog, mode);
  const totals = emptyTotals();
  const groups = new Map<string, UsageSummaryGroup>();
  let breakdownsTruncated = false;
  for (const [index, row] of result.rows.entries()) {
    const fact = facts[index];
    if (!fact) throw new UsageSummaryLimitError();
    addTotals(totals, fact);
    for (const dimension of includeHourlyBreakdowns
      ? breakdownDimensions
      : breakdownDimensions.slice(0, -2)) {
      if (!addGroup(groups, dimension, breakdownKey(row, dimension), fact, index)) {
        breakdownsTruncated = true;
      }
    }
  }
  const breakdowns = [...groups]
    .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0))
    .map(([, group]) => {
      return {
        dimension: group.dimension,
        key: group.key,
        totals: serializedTotals(group.totals),
        cost: boundedFoldPreparedUsageCosts(
          preparedCosts,
          group.rowIndexes,
          includeTruncationFields,
        ),
      };
    });
  return boundedModelResult(() =>
    AccountUsageSummarySchema.parse({
      range,
      totals: serializedTotals(totals),
      cost: boundedFoldPreparedUsageCosts(preparedCosts, undefined, includeTruncationFields),
      coverage: result.coverage.map(coverageSummary),
      breakdowns,
      ...(includeTruncationFields && result.coverage_truncated ? { coverage_truncated: true } : {}),
      ...(includeTruncationFields && breakdownsTruncated ? { breakdowns_truncated: true } : {}),
    }),
  );
}

export function buildUsageCost(
  rows: readonly StoredUsageHourlyFact[],
  mode: UsageCostMode,
  catalog: PricingCatalog,
  includeTruncationFields = true,
): UsageCostOutcome {
  return boundedModelResult(() => {
    const facts = rows.map(usageFact);
    return boundedFoldPreparedUsageCosts(
      prepareUsageCosts(facts, catalog, mode),
      undefined,
      includeTruncationFields,
    );
  });
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
): boolean {
  // Model text is opaque and may contain punctuation such as ':'. Keep the
  // display fields separate instead of recovering them from a delimiter.
  const compound = `${dimension}\u0000${key}`;
  let group = groups.get(compound);
  if (!group) {
    if (groups.size >= MAXIMUM_USAGE_BREAKDOWNS) return false;
    group = { dimension, key, totals: emptyTotals(), rowIndexes: [] };
    groups.set(compound, group);
  }
  addTotals(group.totals, row);
  group.rowIndexes.push(rowIndex);
  return true;
}

interface UsageSummaryGroup {
  dimension: UsageBreakdownDimension;
  key: string;
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

function boundedFoldPreparedUsageCosts(
  prepared: PreparedUsageCosts,
  indexes?: readonly number[],
  includeTruncationFields = true,
): UsageCostOutcome {
  const selected = indexes ?? prepared.rows.map((_, index) => index);
  if (!includeTruncationFields || !hasTooManyUnpricedDetails(prepared, selected)) {
    return foldPreparedUsageCosts(prepared, indexes);
  }

  let calculatedRows = 0;
  let reportedRows = 0;
  let amount = 0n;
  const assumptions = new Set<UsageCostOutcome["assumptions"][number]>();
  const unpriced = new Map<string, UsageUnpricedItem>();
  for (const index of selected) {
    const row = prepared.rows[index];
    if (!row) throw new RangeError(`Missing prepared Usage row at index ${index}.`);
    if (row.status !== "priced") {
      const key = `${row.billing_channel}\u0000${row.model}\u0000${row.reason}`;
      const existing = unpriced.get(key);
      if (existing) existing.rows += 1;
      else {
        unpriced.set(key, {
          billing_channel: row.billing_channel,
          model: row.model,
          reason: row.reason,
          rows: 1,
        });
      }
      continue;
    }
    amount += row.amount_microusd;
    if (row.basis === "calculated") calculatedRows += 1;
    else reportedRows += 1;
    for (const assumption of row.assumptions) assumptions.add(assumption);
  }
  const unpricedRows = selected.length - calculatedRows - reportedRows;
  const details = [...unpriced.values()]
    .sort((left, right) =>
      `${left.billing_channel}\u0000${left.model}\u0000${left.reason}`.localeCompare(
        `${right.billing_channel}\u0000${right.model}\u0000${right.reason}`,
      ),
    )
    .slice(0, MAXIMUM_UNPRICED_ITEMS);
  return UsageCostOutcomeSchema.parse({
    mode: prepared.mode,
    basis:
      calculatedRows > 0 && reportedRows > 0
        ? "mixed"
        : calculatedRows > 0
          ? "calculated"
          : reportedRows > 0
            ? "reported"
            : "none",
    status:
      unpricedRows === 0
        ? "complete"
        : calculatedRows + reportedRows > 0
          ? "partial"
          : "unavailable",
    amount_microusd: calculatedRows + reportedRows > 0 ? amount.toString() : null,
    catalog_revision: prepared.catalog_revision,
    calculated_rows: calculatedRows,
    reported_rows: reportedRows,
    unpriced_rows: unpricedRows,
    assumptions: [...assumptions].sort(),
    unpriced: details,
    unpriced_truncated: true,
  });
}

function hasTooManyUnpricedDetails(
  prepared: PreparedUsageCosts,
  indexes: readonly number[],
): boolean {
  const keys = new Set<string>();
  for (const index of indexes) {
    const row = prepared.rows[index];
    if (!row) throw new RangeError(`Missing prepared Usage row at index ${index}.`);
    if (row.status === "unpriced") {
      keys.add(`${row.billing_channel}\u0000${row.model}\u0000${row.reason}`);
      if (keys.size > MAXIMUM_UNPRICED_ITEMS) return true;
    }
  }
  return false;
}

function boundedModelResult<Result>(operation: () => Result): Result {
  try {
    return operation();
  } catch {
    throw new UsageSummaryLimitError();
  }
}
