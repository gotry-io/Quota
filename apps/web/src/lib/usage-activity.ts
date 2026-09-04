import type { UsageActivityDayRead } from "@gotry-io/quota-protocol";
import { activityLevel, formatCount, WEB_LOCALE } from "./format.ts";

export const ACTIVITY_WEEKDAY_LABELS = ["", "Mon", "", "Wed", "", "Fri", ""] as const;
export const ACTIVITY_TOOLTIP_MARGIN = 8;
export const ACTIVITY_PAGE_DAYS = 30;
const MONTH_LABEL_MIN_WEEKS = 2;
const TOOLTIP_GAP = 8;
const UTC_DATE = /^\d{4}-\d{2}-\d{2}$/;

export type ActivityRange = {
  from: string;
  to: string;
};

type ActivityDay = {
  date: string;
  outside: boolean;
  today: boolean;
  level: number;
  requests: number;
  tokens: number;
  input_tokens: number;
  output_tokens: number;
  cost: UsageActivityDayRead["cost"] | null;
  partial: boolean;
  tooltip: string;
};

type ActivityMonthLabel = {
  weekIndex: number;
  label: string;
  span: number;
};

type ActivityTooltipBox = {
  left: number;
  top: number;
  right: number;
  bottom: number;
};

type ActivityTooltipPlacement = {
  left: number;
  top: number;
  placement: "above" | "below";
};

type UsageActivityModel = {
  days: ActivityDay[];
  weeks: ActivityDay[][];
  monthLabels: ActivityMonthLabel[];
};

type ActivityCostView = Pick<UsageActivityDayRead["cost"], "status" | "amount_microusd" | "basis">;

export type ActivityRoverAction =
  | "next-day"
  | "previous-day"
  | "next-week"
  | "previous-week"
  | "row-start"
  | "row-end"
  | "page-forward"
  | "page-back";

export function formatActivityDate(value: string): string {
  return new Intl.DateTimeFormat(WEB_LOCALE, {
    dateStyle: "long",
    timeZone: "UTC",
  }).format(utcDate(value));
}

function formatActivityMonth(value: string): string {
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

export function usageActivityDayFromQuery(
  value: string | null,
  range: ActivityRange,
): string | null {
  if (value === null || !isUtcDateString(value)) return null;
  if (value < range.from || value > range.to) return null;
  return value;
}

export function usageActivityDayHref(url: URL, day: string | null): string {
  const next = new URL(url);
  if (day === null) next.searchParams.delete("day");
  else next.searchParams.set("day", day);
  return `${next.pathname}${next.search}${next.hash}`;
}

export function activityRoverFromKey(key: string): ActivityRoverAction | "select" | null {
  switch (key) {
    case "ArrowLeft":
      return "previous-day";
    case "ArrowRight":
      return "next-day";
    case "ArrowUp":
      return "previous-week";
    case "ArrowDown":
      return "next-week";
    case "Home":
      return "row-start";
    case "End":
      return "row-end";
    case "PageUp":
      return "page-back";
    case "PageDown":
      return "page-forward";
    case "Enter":
    case " ":
      return "select";
    default:
      return null;
  }
}

export function nextActivityDate(
  days: readonly { date: string; outside: boolean }[],
  current: string,
  action: ActivityRoverAction,
): string {
  const selectable = days.filter((day) => !day.outside).map((day) => day.date);
  const index = selectable.indexOf(current);
  if (index < 0) return current;
  const at = (value: number): string =>
    selectable[Math.min(selectable.length - 1, Math.max(0, value))] ?? current;
  switch (action) {
    case "next-day":
      return at(index + 1);
    case "previous-day":
      return at(index - 1);
    case "next-week":
      return at(index + 7);
    case "previous-week":
      return at(index - 7);
    case "page-forward":
      return at(index + ACTIVITY_PAGE_DAYS);
    case "page-back":
      return at(index - ACTIVITY_PAGE_DAYS);
    case "row-start":
    case "row-end": {
      const allIndex = days.findIndex((day) => day.date === current);
      if (allIndex < 0) return current;
      const weekStart = allIndex - (allIndex % 7);
      const week = days.slice(weekStart, weekStart + 7).filter((day) => !day.outside);
      const edge = action === "row-start" ? week[0] : week.at(-1);
      return edge?.date ?? current;
    }
  }
}

export function buildUsageActivityModel(
  reported: readonly UsageActivityDayRead[],
  range: ActivityRange,
  today: string,
): UsageActivityModel {
  const byDate = new Map(reported.map((day) => [day.date, day]));
  const maxTokens = Math.max(0, ...reported.map((day) => day.totals.total_tokens));
  const days: ActivityDay[] = [];
  for (const date of sundayAlignedDates(range)) {
    const value = byDate.get(date);
    const outside = date < range.from || date > range.to;
    const cost = value?.cost ?? null;
    const tokens = value?.totals.total_tokens ?? 0;
    days.push({
      date,
      outside,
      today: !outside && date === today,
      level: activityLevel(tokens, maxTokens),
      requests: value?.totals.messages ?? 0,
      tokens,
      input_tokens: value?.totals.input_tokens ?? 0,
      output_tokens: value?.totals.output_tokens ?? 0,
      cost,
      partial: value?.partial ?? false,
      tooltip: formatActivityTooltip({ date, tokens, cost }),
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

function isUtcDateString(value: string): boolean {
  return UTC_DATE.test(value) && utcDate(value).toISOString().slice(0, 10) === value;
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
