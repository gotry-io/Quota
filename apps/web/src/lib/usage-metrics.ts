/**
 * The Usage numbers this page derives rather than reads.
 *
 * The cache hit rate is stated once per runtime and answered against
 * `packages/protocol/fixtures/usage-metrics-conformance.json`, so this file calls the shared rule
 * rather than restating it. See ADR 0036. Everything else here is shape: which days a period's
 * table shows, and how one part of a total is named beside the whole.
 *
 * These take the fields they read rather than a whole contract type, because a reader may be
 * shown a member this build has never heard of. See ADR 0023.
 */
import { usageCacheHitBasisPoints } from "@gotry-io/quota-model";
import { formatCost, formatCount, WEB_LOCALE } from "./format.ts";
import type { UsagePeriodQuery } from "./usage-period.ts";

type TotalsView = {
  total_tokens: number;
  input_tokens: number;
  output_tokens: number;
  cache_read_input_tokens: number;
  cache_write_input_tokens: number;
  reasoning_tokens: number;
  messages: number;
};

type CostView = { amount_microusd: string | null; status: string; basis: string };
type SavedView = { amount_microusd: string | null; status: string };

/** How much of a period's input came back from a cache, as whole percent, or `null` for no input. */
export function cacheHitLabel(totals: TotalsView): string | null {
  const basisPoints = usageCacheHitBasisPoints(totals);
  if (basisPoints === null) return null;
  return `${new Intl.NumberFormat(WEB_LOCALE).format(Math.round(basisPoints / 100))}%`;
}

/**
 * What those cache reads saved, or `null` when nothing behind them could be priced.
 *
 * A saving that priced only some of its rows is a lower bound, which is what `formatCost` marks
 * a partial amount with.
 */
export function cacheSavedLabel(saved: SavedView): string | null {
  if (saved.amount_microusd === null) return null;
  return `saved ${formatCost({ ...saved, basis: "calculated" })}`;
}

/** One part of a whole, as whole percent. A whole of zero has no share to state. */
export function shareLabel(part: number, whole: number): string | null {
  if (whole <= 0) return null;
  return `${new Intl.NumberFormat(WEB_LOCALE).format(Math.round((part / whole) * 100))}%`;
}

/** The share as a number between 0 and 1, which is what a bar's width is. */
export function shareFraction(part: number, whole: number): number {
  if (whole <= 0) return 0;
  return Math.min(1, Math.max(0, part / whole));
}

export type UsageDailyRow = {
  date: string;
  totals: TotalsView;
  cost: CostView;
  partial: boolean;
  /** The three shares that add up to `totals.total_tokens`, in the order they stack. */
  segments: { freshInput: number; cachedInput: number; output: number };
};

/**
 * The UTC days a period's table shows, oldest first, including the ones with no Usage.
 *
 * The activity read answers UTC dates — 400 local days would cut 400 UTC days, which is the
 * history the rollup exists to keep closed (ADR 0024) — so this table is UTC too, and says so.
 * `all` has no table: two years of rows is what the activity graph beside it already answers.
 */
export function usageDailyRows(
  days: readonly { date: string; totals: TotalsView; cost: CostView; partial: boolean }[],
  period: UsagePeriodQuery,
  lastDate: string,
): UsageDailyRow[] {
  const span = dailySpan(period);
  if (span === null) return [];
  const byDate = new Map(days.map((day) => [day.date, day]));
  const rows: UsageDailyRow[] = [];
  for (let offset = span - 1; offset >= 0; offset -= 1) {
    const date = shiftUtcDate(lastDate, -offset);
    const day = byDate.get(date);
    const totals = day?.totals ?? emptyTotals();
    rows.push({
      date,
      totals,
      cost: day?.cost ?? { amount_microusd: null, status: "unavailable", basis: "none" },
      partial: day?.partial ?? false,
      segments: {
        freshInput: totals.input_tokens - totals.cache_read_input_tokens,
        cachedInput: totals.cache_read_input_tokens,
        output: totals.output_tokens,
      },
    });
  }
  return rows;
}

/** How many UTC days each period's table covers, or `null` for the period that has no table. */
export function dailySpan(period: UsagePeriodQuery): number | null {
  switch (period) {
    case "today":
      return 1;
    case "7d":
      return 7;
    case "30d":
      return 30;
    case "all":
      return null;
  }
}

/** The tallest bar in the table, which every other bar is drawn against. */
export function dailyMaximum(rows: readonly UsageDailyRow[], mode: "tokens" | "cost"): number {
  return rows.reduce((maximum, row) => Math.max(maximum, dailyValue(row, mode)), 0);
}

/** What one day's bar measures, in tokens or in micro-USD. */
export function dailyValue(row: UsageDailyRow, mode: "tokens" | "cost"): number {
  if (mode === "tokens") return row.totals.total_tokens;
  return Number(row.cost.amount_microusd ?? "0");
}

/** The one line a day's bar carries for a pointer and for a screen reader. */
export function dailyTooltip(row: UsageDailyRow): string {
  return `${row.date} · ${formatCount(row.totals.total_tokens)} tokens · ${formatCost(row.cost)}`;
}

function emptyTotals(): TotalsView {
  return {
    total_tokens: 0,
    input_tokens: 0,
    output_tokens: 0,
    cache_read_input_tokens: 0,
    cache_write_input_tokens: 0,
    reasoning_tokens: 0,
    messages: 0,
  };
}

function shiftUtcDate(date: string, days: number): string {
  const shifted = new Date(`${date}T00:00:00Z`);
  shifted.setUTCDate(shifted.getUTCDate() + days);
  return shifted.toISOString().slice(0, 10);
}

type AgentTreeView = readonly {
  agent: string;
  providers: readonly {
    provider: string;
    models: readonly { model: string; totals: TotalsView; cost: CostView }[];
  }[];
}[];

export type UsageModelShare = {
  agent: string;
  provider: string;
  model: string;
  tokens: number;
  cost: CostView;
};

/** Every model leaf of a period, largest first, so a reader sees what the period was spent on. */
export function usageModelShares(agents: AgentTreeView): UsageModelShare[] {
  return agents
    .flatMap((agent) =>
      agent.providers.flatMap((provider) =>
        provider.models.map((model) => ({
          agent: agent.agent,
          provider: provider.provider,
          model: model.model,
          tokens: model.totals.total_tokens,
          cost: model.cost,
        })),
      ),
    )
    .sort((left, right) => right.tokens - left.tokens || compareText(left.model, right.model));
}

export type UsageProviderShare = { provider: string; tokens: number };

/** One row per provider, largest first: the same leaves, folded to the name that billed them. */
export function usageProviderShares(agents: AgentTreeView): UsageProviderShare[] {
  const tokens = new Map<string, number>();
  for (const model of usageModelShares(agents)) {
    tokens.set(model.provider, (tokens.get(model.provider) ?? 0) + model.tokens);
  }
  return [...tokens]
    .map(([provider, total]) => ({ provider, tokens: total }))
    .sort(
      (left, right) => right.tokens - left.tokens || compareText(left.provider, right.provider),
    );
}

function compareText(left: string, right: string): number {
  if (left === right) return 0;
  return left < right ? -1 : 1;
}
