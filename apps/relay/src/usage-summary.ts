import {
  foldPreparedUsageCosts,
  inferenceProvider,
  type PreparedUsageCosts,
  prepareUsageCosts,
  resolveModel,
} from "@gotry-io/quota-model";
import {
  type AccountUsageSummary,
  AccountUsageSummarySchema,
  type InferenceProvider,
  type LocalUsageAgentSummary,
  MAXIMUM_UNPRICED_ITEMS,
  MAXIMUM_USAGE_BREAKDOWNS,
  type ModelCatalog,
  type PricingCatalog,
  type UsageBreakdownDimension,
  type UsageCostMode,
  type UsageCostOutcome,
  UsageCostOutcomeSchema,
  type UsageHourlyFact,
  type UsageTokenTotals,
  UsageTokenTotalsSchema,
  type UsageUnpricedItem,
} from "@gotry-io/quota-protocol";
import type { StoredUsageHourlyFact, UsageQueryResult } from "@gotry-io/relay-core";

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
  modelCatalog?: ModelCatalog,
  includeClients = false,
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
      : breakdownDimensions.slice(0, -1)) {
      const groupKey = breakdownKey(row, dimension, modelCatalog);
      if (!addGroup(groups, dimension, groupKey.identity, groupKey.key, fact, index)) {
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
        cost: boundedFoldPreparedUsageCosts(preparedCosts, group.rowIndexes),
      };
    });
  const agentSummary = includeClients
    ? buildUsageAgents(result.rows, facts, preparedCosts, modelCatalog)
    : undefined;
  return boundedModelResult(() =>
    AccountUsageSummarySchema.parse({
      range,
      totals: serializedTotals(totals),
      cost: boundedFoldPreparedUsageCosts(preparedCosts),
      coverage: result.coverage,
      breakdowns,
      ...(agentSummary ? { agents: agentSummary.agents } : {}),
      ...(modelCatalog ? { model_catalog_revision: modelCatalog.revision } : {}),
      ...(breakdownsTruncated || agentSummary?.modelsTruncated
        ? { breakdowns_truncated: true }
        : {}),
    }),
  );
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

function buildUsageAgents(
  rows: readonly StoredUsageHourlyFact[],
  facts: readonly UsageHourlyFact[],
  preparedCosts: PreparedUsageCosts,
  modelCatalog?: ModelCatalog,
): { agents: LocalUsageAgentSummary[]; modelsTruncated: boolean } {
  const agents = new Map<string, UsageAgentGroup>();
  let modelCount = 0;
  let modelsTruncated = false;
  for (const [index, row] of rows.entries()) {
    let agent = agents.get(row.agent);
    if (!agent) {
      agent = { agent: row.agent, rowIndexes: [], providers: new Map() };
      agents.set(row.agent, agent);
    }
    agent.rowIndexes.push(index);

    const providerID = inferenceProvider(row.billing_channel);
    let provider = agent.providers.get(providerID);
    if (!provider) {
      provider = { provider: providerID, rowIndexes: [], models: new Map() };
      agent.providers.set(providerID, provider);
    }
    provider.rowIndexes.push(index);

    const modelKey = breakdownKey(row, "model", modelCatalog);
    let model = provider.models.get(modelKey.identity);
    if (!model) {
      if (modelCount === MAXIMUM_USAGE_BREAKDOWNS) {
        modelsTruncated = true;
        continue;
      }
      model = { model: modelKey.key, rowIndexes: [] };
      provider.models.set(modelKey.identity, model);
      modelCount += 1;
    }
    model.rowIndexes.push(index);
  }

  return {
    agents: [...agents.values()]
      .sort((left, right) => left.agent.localeCompare(right.agent))
      .map((agent) => ({
        agent: agent.agent,
        totals: summaryTotals(facts, agent.rowIndexes),
        cost: boundedFoldPreparedUsageCosts(preparedCosts, agent.rowIndexes),
        providers: [...agent.providers.values()]
          .sort((left, right) => left.provider.localeCompare(right.provider))
          .map((provider) => ({
            provider: provider.provider,
            totals: summaryTotals(facts, provider.rowIndexes),
            cost: boundedFoldPreparedUsageCosts(preparedCosts, provider.rowIndexes),
            models: [...provider.models]
              .sort(([left], [right]) => left.localeCompare(right))
              .map(([, model]) => ({
                model: model.model,
                totals: summaryTotals(facts, model.rowIndexes),
                cost: boundedFoldPreparedUsageCosts(preparedCosts, model.rowIndexes),
              })),
          })),
      })),
    modelsTruncated,
  };
}

function summaryTotals(facts: readonly UsageHourlyFact[], indexes: readonly number[]) {
  const totals = emptyTotals();
  for (const index of indexes) {
    const fact = facts[index];
    if (!fact) throw new UsageSummaryLimitError();
    addTotals(totals, fact);
  }
  const totalTokens = totals.input_tokens + totals.output_tokens;
  const cacheWriteInputTokens =
    totals.cache_write_5m_tokens +
    totals.cache_write_1h_tokens +
    totals.cache_write_inferred_tokens;
  if (!Number.isSafeInteger(totalTokens) || !Number.isSafeInteger(cacheWriteInputTokens)) {
    throw new UsageSummaryLimitError();
  }
  return {
    total_tokens: totalTokens,
    input_tokens: totals.input_tokens,
    output_tokens: totals.output_tokens,
    cache_read_input_tokens: totals.cache_read_tokens,
    cache_write_input_tokens: cacheWriteInputTokens,
    reasoning_tokens: totals.reasoning_tokens,
    messages: totals.requests,
  };
}

interface UsageAgentGroup {
  agent: StoredUsageHourlyFact["agent"];
  rowIndexes: number[];
  providers: Map<InferenceProvider, UsageProviderGroup>;
}

interface UsageProviderGroup {
  provider: InferenceProvider;
  rowIndexes: number[];
  models: Map<string, UsageModelGroup>;
}

interface UsageModelGroup {
  model: string;
  rowIndexes: number[];
}

function breakdownKey(
  row: StoredUsageHourlyFact,
  dimension: (typeof breakdownDimensions)[number],
  modelCatalog?: ModelCatalog,
): { identity: string; key: string } {
  switch (dimension) {
    case "device":
      return { identity: row.device_id, key: row.device_id };
    case "agent":
      return { identity: row.agent, key: row.agent };
    case "model": {
      if (!modelCatalog) return { identity: "raw:" + row.model, key: row.model };
      const resolution = resolveModel(modelCatalog, row);
      return resolution
        ? {
            identity: "canonical:" + resolution,
            key: resolution,
          }
        : { identity: "raw:" + row.model, key: row.model };
    }
    case "billing_channel":
      return { identity: row.billing_channel, key: row.billing_channel };
    case "usage_date":
      return { identity: row.usage_date, key: row.usage_date };
    case "bucket_start_utc":
      return { identity: row.bucket_start_utc, key: row.bucket_start_utc };
  }
}

function addGroup(
  groups: Map<string, UsageSummaryGroup>,
  dimension: UsageBreakdownDimension,
  identity: string,
  key: string,
  row: UsageHourlyFact,
  rowIndex: number,
): boolean {
  // Model text is opaque and may contain punctuation such as ':'. Keep the
  // display fields separate instead of recovering them from a delimiter.
  const compound = dimension + "\u0000" + identity;
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
): UsageCostOutcome {
  const selected = indexes ?? prepared.rows.map((_, index) => index);
  if (!hasTooManyUnpricedDetails(prepared, selected)) {
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
