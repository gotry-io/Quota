import {
  type DatedUsageRow,
  type PreparedUsageCosts,
  prepareUsageCosts,
  resolveModel,
  resolveProvider,
} from "@gotry-io/quota-model";
import {
  exceedsContractBound,
  type InferenceProvider,
  MANAGED_DATA_PROTOCOL_VERSION,
  MAXIMUM_PUBLIC_USAGE_MODELS,
  type ModelCatalog,
  type PricingCatalog,
  PUBLIC_ACTIVITY_DAYS,
  PUBLIC_ACTIVITY_MAXIMUM_LEVEL,
  type PublicActivityDay,
  type PublicUsageCost,
  type PublicUsagePeriod,
  type PublicUsageResponse,
  PublicUsageResponseSchema,
} from "@gotry-io/quota-protocol";
import type { StoredUsageDailyRow } from "@gotry-io/relay-core";
import { UsageSummaryLimitError } from "./usage-summary.ts";

/**
 * Cost on a public page is the same number the owner sees on `/my/usage`, arrived at the same
 * way: catalog price where there is one, the provider's own reported cost where there is not.
 */
const publicCostMode = "auto" as const;

export interface PublicUsageInput {
  handle: string;
  publishedAt: string;
  generatedAt: Date;
  /** Every retained day of this Account's rollup, which is what `all` is. */
  daily: readonly StoredUsageDailyRow[];
  showModels: boolean;
  showCost: boolean;
  catalog: PricingCatalog;
  modelCatalog: ModelCatalog;
}

/**
 * The whole answer a public page gives, built from the daily rollup alone.
 *
 * An anonymous reader names no calendar, so both periods and the heatmap are UTC dates: `tz` is
 * a question only a session's own client can be asked. Nothing here reads `usage_hourly`, since
 * a public page has no period edge to cut out of a UTC day.
 */
export function buildPublicUsage(input: PublicUsageInput): PublicUsageResponse {
  const facts = input.daily.map(publicUsageRow);
  const prepared = prepareUsageCosts(facts, input.catalog, publicCostMode);
  const thirtyDaysFrom = utcDaysBefore(input.generatedAt, 29);
  const activityFrom = utcDaysBefore(input.generatedAt, PUBLIC_ACTIVITY_DAYS - 1);
  const recent: number[] = [];
  const everything: number[] = [];
  for (const [index, row] of input.daily.entries()) {
    everything.push(index);
    if (row.date >= thirtyDaysFrom) recent.push(index);
  }
  const period = (indexes: readonly number[]): PublicUsagePeriod =>
    buildPublicPeriod(facts, prepared, indexes, input);
  return boundedResult(() =>
    PublicUsageResponseSchema.parse({
      protocol_version: MANAGED_DATA_PROTOCOL_VERSION,
      handle: input.handle,
      published_at: input.publishedAt,
      generated_at: input.generatedAt.toISOString(),
      last_30_days: period(recent),
      all: period(everything),
      activity: buildPublicActivity(input.daily, activityFrom, input.generatedAt),
    }),
  );
}

function buildPublicPeriod(
  facts: readonly DatedUsageRow[],
  prepared: PreparedUsageCosts,
  indexes: readonly number[],
  input: PublicUsageInput,
): PublicUsagePeriod {
  let inputTokens = 0;
  let outputTokens = 0;
  let messages = 0;
  const providers = new Map<InferenceProvider, number>();
  const models = new Map<string, { provider: InferenceProvider; model: string; tokens: number }>();
  for (const index of indexes) {
    const fact = facts[index];
    if (!fact) throw new UsageSummaryLimitError();
    inputTokens += fact.input_tokens;
    outputTokens += fact.output_tokens;
    messages += fact.requests;
    const tokens = fact.input_tokens + fact.output_tokens;
    const provider = resolveProvider(input.modelCatalog, fact);
    providers.set(provider, (providers.get(provider) ?? 0) + tokens);
    if (!input.showModels) continue;
    const model = resolveModel(input.modelCatalog, fact) ?? fact.model;
    const key = JSON.stringify([provider, model]);
    const existing = models.get(key);
    if (existing) existing.tokens += tokens;
    else models.set(key, { provider, model, tokens });
  }
  const total = inputTokens + outputTokens;
  return {
    totals: {
      total_tokens: total,
      input_tokens: inputTokens,
      output_tokens: outputTokens,
      messages,
    },
    ...(input.showCost ? { cost: publicCost(prepared, indexes) } : {}),
    providers: [...providers]
      .sort(
        ([leftProvider, left], [rightProvider, right]) =>
          right - left || compareText(leftProvider, rightProvider),
      )
      .map(([provider, tokens]) => ({
        provider,
        total_tokens: tokens,
        share_permille: permille(tokens, total),
      })),
    ...(input.showModels
      ? {
          models: [...models.values()]
            .sort(
              (left, right) =>
                right.tokens - left.tokens ||
                compareText(left.provider, right.provider) ||
                compareText(left.model, right.model),
            )
            .slice(0, MAXIMUM_PUBLIC_USAGE_MODELS)
            .map((leaf) => ({
              provider: leaf.provider,
              model: leaf.model,
              total_tokens: leaf.tokens,
              share_permille: permille(leaf.tokens, total),
            })),
        }
      : {}),
  };
}

/**
 * The priced part of a period, without the detail the owner's own read carries.
 *
 * A public page states an amount and whether everything in it could be priced. Which rows could
 * not be priced is named on `/my/usage`, where the person who can act on it is the one reading.
 */
function publicCost(prepared: PreparedUsageCosts, indexes: readonly number[]): PublicUsageCost {
  let amount = 0n;
  let priced = 0;
  let unpriced = 0;
  for (const index of indexes) {
    const row = prepared.rows[index];
    if (!row) throw new UsageSummaryLimitError();
    if (row.status !== "priced") {
      unpriced += 1;
      continue;
    }
    amount += row.amount_microusd;
    priced += 1;
  }
  return {
    amount_microusd: priced > 0 ? amount.toString() : null,
    status: unpriced === 0 ? "complete" : priced > 0 ? "partial" : "unavailable",
  };
}

/**
 * A year of the heatmap, as bands rather than counts.
 *
 * The band is taken against the busiest day of the same year, so the shape of a year is
 * readable while no cell states a number. A day with no Usage is left out rather than sent as a
 * zero: the page draws the calendar itself, and a date it does not receive is level 0.
 */
function buildPublicActivity(
  rows: readonly StoredUsageDailyRow[],
  from: string,
  generatedAt: Date,
): PublicActivityDay[] {
  const to = utcDate(generatedAt);
  const byDate = new Map<string, number>();
  for (const row of rows) {
    if (row.date < from || row.date > to) continue;
    byDate.set(row.date, (byDate.get(row.date) ?? 0) + row.input_tokens + row.output_tokens);
  }
  const busiest = Math.max(0, ...byDate.values());
  return [...byDate]
    .filter(([, tokens]) => tokens > 0)
    .sort(([left], [right]) => compareText(left, right))
    .map(([date, tokens]) => ({ date, level: activityLevel(tokens, busiest) }));
}

/** The same band the account's own Activity graph draws, so one page cannot contradict another. */
function activityLevel(tokens: number, busiest: number): number {
  if (tokens <= 0 || busiest <= 0) return 0;
  return Math.min(
    PUBLIC_ACTIVITY_MAXIMUM_LEVEL,
    Math.ceil((tokens / busiest) * PUBLIC_ACTIVITY_MAXIMUM_LEVEL),
  );
}

function permille(part: number, total: number): number {
  if (total <= 0) return 0;
  return Math.min(1_000, Math.round((part / total) * 1_000));
}

function publicUsageRow(row: StoredUsageDailyRow): DatedUsageRow {
  const { device_id: _device, partial_hours: _partial, ...fact } = row;
  return fact;
}

function compareText(left: string, right: string): number {
  if (left === right) return 0;
  return left < right ? -1 : 1;
}

function utcDate(instant: Date): string {
  return instant.toISOString().slice(0, 10);
}

function utcDaysBefore(instant: Date, days: number): string {
  return utcDate(new Date(instant.getTime() - days * 86_400_000));
}

/**
 * A total this contract cannot carry is a request for too much, not a failure of this build.
 * Everything else travels as itself. The same rule as the Account summary's own fold.
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
