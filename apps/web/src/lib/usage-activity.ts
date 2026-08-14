import type { UsageBreakdown, UsageCostOutcome } from "@gotry-io/quota-protocol";
import { activityLevel, formatCount, safeAdd, WEB_LOCALE } from "./format.ts";

export const ACTIVITY_WEEKDAY_LABELS = ["", "Mon", "", "Wed", "", "Fri", ""] as const;
export const ACTIVITY_TOOLTIP_MARGIN = 8;
const MONTH_LABEL_MIN_WEEKS = 2;
const TOOLTIP_GAP = 8;

export type ActivityRange = {
  from: string;
  to: string;
};

export type ActivityDay = {
  date: string;
  outside: boolean;
  today: boolean;
  level: number;
  requests: number;
  tokens: number;
  input_tokens: number;
  output_tokens: number;
  cost: UsageCostOutcome | null;
  tooltip: string;
};

export type ActivityMonthLabel = {
  weekIndex: number;
  label: string;
  span: number;
};

export type ActivityTooltipBox = {
  left: number;
  top: number;
  right: number;
  bottom: number;
};

export type ActivityTooltipPlacement = {
  left: number;
  top: number;
  placement: "above" | "below";
};

export type UsageActivityModel = {
  days: ActivityDay[];
  weeks: ActivityDay[][];
  monthLabels: ActivityMonthLabel[];
};

export type ActivityCostView = Pick<UsageCostOutcome, "status" | "amount_microusd" | "basis">;

export function usageDateBreakdowns(items: readonly UsageBreakdown[]): UsageBreakdown[] {
  return items.filter((item) => item.dimension === "usage_date");
}

export function formatActivityDate(value: string): string {
  return new Intl.DateTimeFormat(WEB_LOCALE, {
    dateStyle: "long",
    timeZone: "UTC",
  }).format(utcDate(value));
}

export function formatActivityMonth(value: string): string {
  return new Intl.DateTimeFormat(WEB_LOCALE, {
    month: "short",
    timeZone: "UTC",
  }).format(utcDate(value));
}

export function placeActivityTooltip(input: {
  cell: ActivityTooltipBox;
  viewport: { width: number; height: number };
  tooltip: { width: number; height: number };
  gap?: number;
  margin?: number;
}): ActivityTooltipPlacement {
  const gap = input.gap ?? TOOLTIP_GAP;
  const margin = input.margin ?? ACTIVITY_TOOLTIP_MARGIN;
  const maxWidth = Math.max(0, input.viewport.width - margin * 2);
  const width = Math.min(input.tooltip.width, maxWidth);
  const height = input.tooltip.height;
  const preferredLeft = (input.cell.left + input.cell.right) / 2 - width / 2;
  const left = clamp(
    preferredLeft,
    margin,
    Math.max(margin, input.viewport.width - margin - width),
  );
  const above = input.cell.top - gap - height;
  if (above >= margin) {
    return { left, top: above, placement: "above" };
  }
  const below = input.cell.bottom + gap;
  const top = clamp(below, margin, Math.max(margin, input.viewport.height - margin - height));
  return { left, top, placement: "below" };
}

export function formatActivityTooltip(input: {
  date: string;
  tokens: number;
  cost: ActivityCostView | null;
}): string {
  const date = formatActivityDate(input.date);
  const tokens = `${formatCount(input.tokens)} tokens`;
  if (
    input.cost === null ||
    input.cost.status === "unavailable" ||
    input.cost.amount_microusd === null
  ) {
    return `${date} · ${tokens} · — Unpriced`;
  }
  return `${date} · ${tokens} · ${formatActivityPrice(input.cost)} API-equivalent · ${tooltipSemantics(input.cost)}`;
}

export function usageDayCoverageLabel(
  coverage: readonly { status: string }[],
  truncated = false,
): string {
  if (coverage.length === 0) {
    return truncated ? "No coverage list · truncated" : "No coverage reported";
  }
  const label = coverage.every((item) => item.status === "complete") ? "Complete" : "Partial";
  return truncated ? `${label} · truncated` : label;
}

export function usageDayNotices(usage: {
  totals: { input_tokens: number; output_tokens: number; requests: number };
  breakdowns: readonly unknown[];
  coverage_truncated?: true | undefined;
  breakdowns_truncated?: true | undefined;
}): string[] {
  const notices: string[] = [];
  if (
    usage.totals.input_tokens === 0 &&
    usage.totals.output_tokens === 0 &&
    usage.totals.requests === 0 &&
    usage.breakdowns.length === 0
  ) {
    notices.push("No Usage has been synced for this day.");
  }
  if (usage.coverage_truncated) notices.push("Some coverage windows were omitted.");
  if (usage.breakdowns_truncated) notices.push("Some agent or model rows were omitted.");
  return notices;
}

export function buildUsageActivityModel(
  breakdowns: readonly UsageBreakdown[],
  range: ActivityRange,
  today: string,
): UsageActivityModel {
  const byDate = totalsByDate(breakdowns, range);
  const maxTokens = Math.max(0, ...[...byDate.values()].map((value) => value.tokens));
  const days: ActivityDay[] = [];
  for (const date of sundayAlignedDates(range)) {
    const value = byDate.get(date);
    const outside = date < range.from || date > range.to;
    const cost = value?.cost ?? null;
    days.push({
      date,
      outside,
      today: !outside && date === today,
      level: activityLevel(value?.tokens ?? 0, maxTokens),
      requests: value?.requests ?? 0,
      tokens: value?.tokens ?? 0,
      input_tokens: value?.input_tokens ?? 0,
      output_tokens: value?.output_tokens ?? 0,
      cost,
      tooltip: formatActivityTooltip({ date, tokens: value?.tokens ?? 0, cost }),
    });
  }
  const weeks = chunkWeeks(days);
  return {
    days,
    weeks,
    monthLabels: monthLabelsForWeeks(weeks),
  };
}

function formatActivityPrice(cost: ActivityCostView): string {
  const microusd = cost.amount_microusd ?? "0";
  const cents = (BigInt(microusd) + 5_000n) / 10_000n;
  const amount = `${new Intl.NumberFormat(WEB_LOCALE).format(cents / 100n)}.${(cents % 100n)
    .toString()
    .padStart(2, "0")}`;
  return `${cost.status === "partial" ? "≥ " : ""}$${amount}`;
}

function tooltipSemantics(cost: ActivityCostView): string {
  if (cost.status === "partial") return "priced subset only";
  return cost.basis === "calculated" ? "estimated" : cost.basis;
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}

function utcDate(value: string): Date {
  return new Date(`${value}T00:00:00Z`);
}

function totalsByDate(
  breakdowns: readonly UsageBreakdown[],
  range: ActivityRange,
): Map<
  string,
  {
    requests: number;
    tokens: number;
    input_tokens: number;
    output_tokens: number;
    cost: UsageCostOutcome;
  }
> {
  const map = new Map<
    string,
    {
      requests: number;
      tokens: number;
      input_tokens: number;
      output_tokens: number;
      cost: UsageCostOutcome;
    }
  >();
  for (const breakdown of usageDateBreakdowns(breakdowns)) {
    if (breakdown.key < range.from || breakdown.key > range.to) continue;
    const current = map.get(breakdown.key) ?? {
      requests: 0,
      tokens: 0,
      input_tokens: 0,
      output_tokens: 0,
      cost: breakdown.cost,
    };
    current.requests = safeAdd(current.requests, breakdown.totals.requests);
    current.input_tokens = safeAdd(current.input_tokens, breakdown.totals.input_tokens);
    current.output_tokens = safeAdd(current.output_tokens, breakdown.totals.output_tokens);
    current.tokens = safeAdd(
      current.tokens,
      breakdown.totals.input_tokens,
      breakdown.totals.output_tokens,
    );
    current.cost = breakdown.cost;
    map.set(breakdown.key, current);
  }
  return map;
}

function sundayAlignedDates(range: ActivityRange): string[] {
  const first = utcDate(range.from);
  first.setUTCDate(first.getUTCDate() - first.getUTCDay());
  const last = utcDate(range.to);
  last.setUTCDate(last.getUTCDate() + (6 - last.getUTCDay()));
  const dates: string[] = [];
  for (const cursor = new Date(first); cursor <= last; cursor.setUTCDate(cursor.getUTCDate() + 1)) {
    dates.push(cursor.toISOString().slice(0, 10));
  }
  return dates;
}

function chunkWeeks(days: ActivityDay[]): ActivityDay[][] {
  const weeks: ActivityDay[][] = [];
  for (let index = 0; index < days.length; index += 7) {
    weeks.push(days.slice(index, index + 7));
  }
  return weeks;
}

function monthLabelsForWeeks(weeks: ActivityDay[][]): ActivityMonthLabel[] {
  const starts: Array<{ weekIndex: number; label: string }> = [];
  const seen = new Set<string>();
  for (const [weekIndex, week] of weeks.entries()) {
    for (const day of week) {
      if (day.outside) continue;
      const month = day.date.slice(0, 7);
      if (seen.has(month)) continue;
      seen.add(month);
      starts.push({ weekIndex, label: formatActivityMonth(day.date) });
    }
  }
  const placed: Array<{ weekIndex: number; label: string }> = [];
  for (const start of starts) {
    const previous = placed.at(-1);
    if (previous && start.weekIndex - previous.weekIndex < MONTH_LABEL_MIN_WEEKS) {
      continue;
    }
    placed.push(start);
  }
  return placed.map((item, index) => ({
    ...item,
    span: (placed[index + 1]?.weekIndex ?? weeks.length) - item.weekIndex,
  }));
}
