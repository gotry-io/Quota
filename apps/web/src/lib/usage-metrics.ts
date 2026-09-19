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
import type { UsageDateRange } from "./usage-period.ts";

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

/**
 * What those cache reads saved, or `null` when nothing behind them could be priced.
 *
 * A saving that priced only some of its rows is a lower bound, which is what `formatCost` marks
 * a partial amount with.
 */
export function cacheSavedLabel(saved: SavedView): string | null {
  if (saved.amount_microusd === null) return null;
  return `saved ${formatCost(saved)}`;
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
  /** False when this local date is in the asked range but absent from `days[]`. */
  recorded: boolean;
  totals: TotalsView;
  cost: CostView;
  partial: boolean;
  /** The three shares that add up to `totals.total_tokens`, in the order they stack. */
  segments: { freshInput: number; cachedInput: number; output: number };
};

export const NO_USAGE_RECORDED = "no usage recorded";

/**
 * One slot per local date in the period's asked `[from, to]`, oldest first.
 *
 * A date absent from `days[]` keeps its axis slot and is a gap, not a $0 / 0-token day
 * (ADR 0055). `all` has no Daily panel; its per-day shape is the Activity graph.
 */
export function usageDailyRows(
  days: readonly { date: string; totals: TotalsView; cost: CostView; partial: boolean }[],
  range: UsageDateRange | null,
): UsageDailyRow[] {
  if (range === null || range.from > range.to) return [];
  const byDate = new Map(days.map((day) => [day.date, day]));
  const rows: UsageDailyRow[] = [];
  for (let date = range.from; date <= range.to; date = shiftUtcDate(date, 1)) {
    const day = byDate.get(date);
    if (day === undefined) {
      rows.push(missingDailyRow(date));
      continue;
    }
    rows.push({
      date,
      recorded: true,
      totals: day.totals,
      cost: day.cost,
      partial: day.partial,
      segments: {
        freshInput: day.totals.input_tokens - day.totals.cache_read_input_tokens,
        cachedInput: day.totals.cache_read_input_tokens,
        output: day.totals.output_tokens,
      },
    });
  }
  return rows;
}

/** The tallest bar in the table, which every other bar is drawn against. */
export function dailyMaximum(rows: readonly UsageDailyRow[], mode: "tokens" | "cost"): number {
  return rows.reduce((maximum, row) => Math.max(maximum, dailyValue(row, mode)), 0);
}

/** What one day's bar measures, in tokens or in micro-USD. Unpriced cost is not a zero. */
export function dailyValue(row: UsageDailyRow, mode: "tokens" | "cost"): number {
  if (mode === "tokens") return row.totals.total_tokens;
  if (row.cost.status === "unavailable") return 0;
  return Number(row.cost.amount_microusd ?? "0");
}

export type DailyBarKind = "amount" | "empty" | "unpriced";

/** How one local day is drawn: a quantitative bar, a baseline tick, or an unpriced mark. */
export function dailyBarKind(row: UsageDailyRow, mode: "tokens" | "cost"): DailyBarKind {
  if (!row.recorded) return "empty";
  if (mode === "tokens") return row.totals.total_tokens > 0 ? "amount" : "empty";
  if (row.totals.total_tokens === 0) return "empty";
  if (row.cost.status === "unavailable") return "unpriced";
  return dailyValue(row, "cost") > 0 ? "amount" : "empty";
}

/** The one line a day's bar carries for a pointer and for a screen reader. */
export function dailyTooltip(row: UsageDailyRow, mode: "tokens" | "cost" = "tokens"): string {
  if (!row.recorded) return `${row.date} · ${NO_USAGE_RECORDED}`;
  if (mode === "tokens") {
    return `${row.date} · ${formatCount(row.totals.total_tokens)} tokens`;
  }
  if (dailyBarKind(row, "cost") === "unpriced") return `${row.date} · unpriced`;
  return `${row.date} · ${formatCost(row.cost)}`;
}

/** Spoken summary of the plot, following Tokens / Cost mode. */
export function dailyChartSummary(rows: readonly UsageDailyRow[], mode: "tokens" | "cost"): string {
  const recorded = rows.filter((row) => row.recorded);
  if (mode === "tokens") {
    const total = recorded.reduce((sum, row) => sum + row.totals.total_tokens, 0);
    return `${rows.length} days, ${formatCount(total)} tokens in total`;
  }
  const unpriced = recorded.filter((row) => dailyBarKind(row, "cost") === "unpriced").length;
  const priced = recorded.filter((row) => dailyBarKind(row, "cost") === "amount");
  if (priced.length === 0) {
    return unpriced > 0
      ? `${rows.length} days, ${unpriced} unpriced`
      : `${rows.length} days, no cost`;
  }
  const amount = priced.reduce((sum, row) => sum + dailyValue(row, "cost"), 0);
  const costText = formatCost({ amount_microusd: String(amount), status: "complete" });
  if (unpriced === 0) return `${rows.length} days, ${costText} in total`;
  return `${rows.length} days, ${costText} in total, ${unpriced} unpriced`;
}

function missingDailyRow(date: string): UsageDailyRow {
  return {
    date,
    recorded: false,
    totals: {
      total_tokens: 0,
      input_tokens: 0,
      output_tokens: 0,
      cache_read_input_tokens: 0,
      cache_write_input_tokens: 0,
      reasoning_tokens: 0,
      messages: 0,
    },
    cost: { amount_microusd: null, status: "unavailable", basis: "none" },
    partial: false,
    segments: { freshInput: 0, cachedInput: 0, output: 0 },
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
