import {
  type DatedUsageRow,
  foldPreparedUsageCosts,
  inferenceProvider,
  type PreparedUsageCosts,
  prepareUsageCosts,
  resolveModel,
} from "@gotry-io/quota-model";
import {
  type AccountUsage,
  AccountUsageSchema,
  type InferenceProvider,
  MAXIMUM_UNPRICED_ITEMS,
  MAXIMUM_USAGE_PERIOD_LEAVES,
  type ModelCatalog,
  type PricingCatalog,
  USAGE_OTHER_MODEL,
  type UsageActivityDay,
  UsageActivityDaySchema,
  exceedsContractBound,
  type UsageCostOutcome,
  UsageCostOutcomeSchema,
  type UsagePeriod,
  UsagePeriodSchema,
  type UsageSummaryTotals,
  type UsageUnpricedItem,
} from "@gotry-io/quota-protocol";
import type { StoredUsageDailyRow } from "@gotry-io/relay-core";
import { LOCAL_PERIOD_KEYS, type LocalPeriodKey, type UsageDateWindow } from "./local-periods.ts";

/**
 * Cost is resolved from the catalog and falls back to what a provider itself reported when the
 * catalog cannot price a row. The other modes only ever narrowed that answer, and no reader
 * asked for a narrower one.
 */
const accountCostMode = "auto" as const;

export class UsageSummaryLimitError extends Error {
  constructor() {
    super("Usage summary exceeds the response limit");
    this.name = "UsageSummaryLimitError";
  }
}

/** Rows the rollup could not answer for, and the periods that fold them. */
export interface AccountUsageBoundary {
  periods: readonly LocalPeriodKey[];
  rows: readonly StoredUsageDailyRow[];
}

export interface AccountUsageInput {
  /** Every retained day of the rollup, which is what `all` is. */
  daily: readonly StoredUsageDailyRow[];
  boundaries: readonly AccountUsageBoundary[];
  /** The whole UTC days each local period folds from the rollup. */
  days: Record<LocalPeriodKey, UsageDateWindow | null>;
  catalog: PricingCatalog;
  modelCatalog: ModelCatalog;
}

/**
 * The four periods an Account read answers.
 *
 * `all` is the rollup entire. The other three cover local days, so each folds the whole UTC days
 * inside it from the rollup and the hours its edges cut from `usage_hourly` — every instant it
 * covers counted once, from exactly one of the two.
 *
 * Prices are resolved once per row and every period selects from that, so a row inside three
 * windows is priced once rather than three times.
 */
export function buildAccountUsage(input: AccountUsageInput): AccountUsage {
  const rows = [...input.daily, ...input.boundaries.flatMap((boundary) => boundary.rows)];
  const facts = rows.map(usageRow);
  const prepared = prepareUsageCosts(facts, input.catalog, accountCostMode);
  const selected = selectPeriods(input);
  const period = (indexes: readonly number[]) =>
    buildUsagePeriod(rows, facts, prepared, indexes, input.modelCatalog);
  return boundedResult(() =>
    AccountUsageSchema.parse({
      today: period(selected.today),
      last_7_days: period(selected.last_7_days),
      last_30_days: period(selected.last_30_days),
      all: period(input.daily.map((_, index) => index)),
    }),
  );
}

/** One entry per UTC date that has Usage, in date order. */
export function buildActivityDays(input: {
  rows: readonly StoredUsageDailyRow[];
  catalog: PricingCatalog;
}): UsageActivityDay[] {
  const facts = input.rows.map(usageRow);
  const prepared = prepareUsageCosts(facts, input.catalog, accountCostMode);
  const byDate = new Map<string, number[]>();
  for (const [index, row] of input.rows.entries()) {
    const indexes = byDate.get(row.date);
    if (indexes) indexes.push(index);
    else byDate.set(row.date, [index]);
  }
  return boundedResult(() =>
    [...byDate]
      .sort(([left], [right]) => compareText(left, right))
      .map(([date, indexes]) =>
        UsageActivityDaySchema.parse({
          date,
          totals: summaryTotals(facts, indexes),
          cost: boundedFoldPreparedUsageCosts(prepared, indexes),
          partial: indexes.some((index) => (input.rows[index]?.partial_hours ?? 0) > 0),
        }),
      ),
  );
}

/** Which of the folded rows each local period takes, over the rows `buildAccountUsage` laid out. */
function selectPeriods(input: AccountUsageInput): Record<LocalPeriodKey, number[]> {
  const selected: Record<LocalPeriodKey, number[]> = {
    today: [],
    last_7_days: [],
    last_30_days: [],
  };
  for (const [index, row] of input.daily.entries()) {
    for (const key of LOCAL_PERIOD_KEYS) {
      const window = input.days[key];
      if (window && row.date >= window.from && row.date <= window.to) selected[key].push(index);
    }
  }
  let offset = input.daily.length;
  for (const boundary of input.boundaries) {
    for (const index of boundary.rows.keys()) {
      for (const key of boundary.periods) selected[key].push(offset + index);
    }
    offset += boundary.rows.length;
  }
  return selected;
}

function usageRow(row: StoredUsageDailyRow): DatedUsageRow {
  const { device_id: _device, partial_hours: _partial, ...fact } = row;
  return fact;
}

function buildUsagePeriod(
  rows: readonly StoredUsageDailyRow[],
  facts: readonly DatedUsageRow[],
  prepared: PreparedUsageCosts,
  indexes: readonly number[],
  modelCatalog: ModelCatalog,
): UsagePeriod {
  return UsagePeriodSchema.parse({
    totals: summaryTotals(facts, indexes),
    cost: boundedFoldPreparedUsageCosts(prepared, indexes),
    partial: indexes.some((index) => (rows[index]?.partial_hours ?? 0) > 0),
    agents: buildAgentTree(facts, prepared, indexes, modelCatalog),
  });
}

interface UsageLeaf {
  agent: string;
  provider: InferenceProvider;
  model: string;
  indexes: number[];
  tokens: number;
}

/**
 * The agent tree for one period, bounded by its leaf count.
 *
 * A tree that would carry more model leaves than the contract allows keeps the largest and
 * folds the rest into an `other` leaf under the provider they belong to, so a response cannot
 * grow without bound and nothing folded is missing from the totals above it.
 */
function buildAgentTree(
  facts: readonly DatedUsageRow[],
  prepared: PreparedUsageCosts,
  indexes: readonly number[],
  modelCatalog: ModelCatalog,
): unknown[] {
  const leaves = new Map<string, UsageLeaf>();
  for (const index of indexes) {
    const fact = facts[index];
    if (!fact) throw new UsageSummaryLimitError();
    const provider = inferenceProvider(fact.billing_channel);
    const model = resolveModel(modelCatalog, fact) ?? fact.model;
    const key = leafKey(fact.agent, provider, model);
    let leaf = leaves.get(key);
    if (!leaf) {
      leaf = { agent: fact.agent, provider, model, indexes: [], tokens: 0 };
      leaves.set(key, leaf);
    }
    leaf.indexes.push(index);
    leaf.tokens = addSafe(leaf.tokens, addSafe(fact.input_tokens, fact.output_tokens));
  }

  const agents = new Map<string, Map<InferenceProvider, UsageLeaf[]>>();
  for (const leaf of boundLeaves([...leaves.values()])) {
    let providers = agents.get(leaf.agent);
    if (!providers) {
      providers = new Map();
      agents.set(leaf.agent, providers);
    }
    const models = providers.get(leaf.provider);
    if (models) models.push(leaf);
    else providers.set(leaf.provider, [leaf]);
  }

  return [...agents]
    .sort(([left], [right]) => compareText(left, right))
    .map(([agent, providers]) => ({
      agent,
      providers: [...providers]
        .sort(([left], [right]) => compareText(left, right))
        .map(([provider, models]) => ({
          provider,
          models: models
            .sort((left, right) => compareText(left.model, right.model))
            .map((leaf) => ({
              model: leaf.model,
              totals: summaryTotals(facts, leaf.indexes),
              cost: boundedFoldPreparedUsageCosts(prepared, leaf.indexes),
            })),
        })),
    }));
}

function boundLeaves(leaves: readonly UsageLeaf[]): UsageLeaf[] {
  if (leaves.length <= MAXIMUM_USAGE_PERIOD_LEAVES) return [...leaves];
  const ranked = [...leaves].sort(
    (left, right) =>
      right.tokens - left.tokens ||
      compareText(left.agent, right.agent) ||
      compareText(left.provider, right.provider) ||
      compareText(left.model, right.model),
  );
  // How many `other` leaves the tail would need if the split were made at each position, so the
  // budget covers both what is kept and what replaces the rest.
  const branches = new Set<string>();
  const tailBranches: number[] = new Array(ranked.length + 1).fill(0);
  for (let index = ranked.length - 1; index >= 0; index -= 1) {
    const leaf = ranked[index];
    if (leaf) branches.add(leafKey(leaf.agent, leaf.provider, ""));
    tailBranches[index] = branches.size;
  }
  let split = 0;
  for (let candidate = MAXIMUM_USAGE_PERIOD_LEAVES; candidate >= 0; candidate -= 1) {
    if (candidate + (tailBranches[candidate] ?? 0) <= MAXIMUM_USAGE_PERIOD_LEAVES) {
      split = candidate;
      break;
    }
  }
  const folded = new Map<string, UsageLeaf>();
  for (const leaf of ranked.slice(split)) {
    const key = leafKey(leaf.agent, leaf.provider, "");
    const existing = folded.get(key);
    if (existing) {
      existing.indexes.push(...leaf.indexes);
      existing.tokens = addSafe(existing.tokens, leaf.tokens);
      continue;
    }
    folded.set(key, {
      agent: leaf.agent,
      provider: leaf.provider,
      model: USAGE_OTHER_MODEL,
      indexes: [...leaf.indexes],
      tokens: leaf.tokens,
    });
  }
  return [...ranked.slice(0, split), ...folded.values()];
}

/** Model text is provider-owned and may contain any punctuation, so the parts are quoted. */
function leafKey(agent: string, provider: string, model: string): string {
  return JSON.stringify([agent, provider, model]);
}

function summaryTotals(
  facts: readonly DatedUsageRow[],
  indexes: readonly number[],
): UsageSummaryTotals {
  let input = 0;
  let output = 0;
  let cacheRead = 0;
  let cacheWrite = 0;
  let reasoning = 0;
  let requests = 0;
  for (const index of indexes) {
    const fact = facts[index];
    if (!fact) throw new UsageSummaryLimitError();
    input = addSafe(input, fact.input_tokens);
    output = addSafe(output, fact.output_tokens);
    cacheRead = addSafe(cacheRead, fact.cache_read_tokens);
    cacheWrite = addSafe(
      cacheWrite,
      fact.cache_write_5m_tokens + fact.cache_write_1h_tokens + fact.cache_write_inferred_tokens,
    );
    reasoning = addSafe(reasoning, fact.reasoning_tokens);
    requests = addSafe(requests, fact.requests);
  }
  return {
    total_tokens: addSafe(input, output),
    input_tokens: input,
    output_tokens: output,
    cache_read_input_tokens: cacheRead,
    cache_write_input_tokens: cacheWrite,
    reasoning_tokens: reasoning,
    messages: requests,
  };
}

function addSafe(left: number, right: number): number {
  const total = left + right;
  if (!Number.isSafeInteger(total)) throw new UsageSummaryLimitError();
  return total;
}

function compareText(left: string, right: string): number {
  if (left === right) return 0;
  return left < right ? -1 : 1;
}

/**
 * Fold a selected set of prepared rows, keeping the unpriced detail bounded.
 *
 * The detail list names every distinct channel/model/reason that could not be priced. An
 * account with more of those than the contract carries reports the count and marks the list
 * truncated rather than failing the whole read.
 */
function boundedFoldPreparedUsageCosts(
  prepared: PreparedUsageCosts,
  indexes: readonly number[],
): UsageCostOutcome {
  if (!hasTooManyUnpricedDetails(prepared, indexes)) {
    return foldPreparedUsageCosts(prepared, indexes);
  }

  let calculatedRows = 0;
  let reportedRows = 0;
  let amount = 0n;
  const assumptions = new Set<UsageCostOutcome["assumptions"][number]>();
  const unpriced = new Map<string, UsageUnpricedItem>();
  for (const index of indexes) {
    const row = prepared.rows[index];
    if (!row) throw new UsageSummaryLimitError();
    if (row.status !== "priced") {
      const key = unpricedKey(row.billing_channel, row.model, row.reason);
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
  const unpricedRows = indexes.length - calculatedRows - reportedRows;
  const details = [...unpriced.values()]
    .sort((left, right) =>
      compareText(
        unpricedKey(left.billing_channel, left.model, left.reason),
        unpricedKey(right.billing_channel, right.model, right.reason),
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

function unpricedKey(channel: string, model: string, reason: string): string {
  return JSON.stringify([channel, model, reason]);
}

function hasTooManyUnpricedDetails(
  prepared: PreparedUsageCosts,
  indexes: readonly number[],
): boolean {
  const keys = new Set<string>();
  for (const index of indexes) {
    const row = prepared.rows[index];
    if (!row) throw new UsageSummaryLimitError();
    if (row.status === "unpriced") {
      keys.add(unpricedKey(row.billing_channel, row.model, row.reason));
      if (keys.size > MAXIMUM_UNPRICED_ITEMS) return true;
    }
  }
  return false;
}

/**
 * Run something that can overrun the contract, and say so when it does.
 *
 * Only two failures mean "this answer does not fit": a total this module cannot add without
 * losing precision, and a schema refusing a value for overrunning a bound it states. Everything
 * else — a bug here, a catalog that cannot be read, a stored row the contract does not describe —
 * is a failure of this build and travels to the error handler as itself, so it is logged as a
 * 500 rather than dressed up as a caller asking for too much.
 */
function boundedResult<Result>(operation: () => Result): Result {
  try {
    return operation();
  } catch (error) {
    if (error instanceof UsageSummaryLimitError) throw error;
    if (exceedsContractBound(error)) throw new UsageSummaryLimitError();
    throw error;
  }
}
