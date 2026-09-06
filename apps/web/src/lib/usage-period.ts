/**
 * Which period the Usage page is showing, and how the URL carries it.
 *
 * Three periods are anchored to this browser's own calendar and step: a day, a week, and a month,
 * each an offset back from the current one. Two are the trailing windows the Account summary
 * already folds, `all` is everything retained, and `custom` is a range someone picked. The
 * phrases are in `apps/menubar/DESIGN.md` Shared product vocabulary.
 *
 * A period the summary does not carry is folded out of the activity days the page already holds
 * (`foldUsageActivityDays`). Those days are UTC days, so an anchored range is chosen in the
 * browser's calendar and then folded from the UTC days that carry those dates.
 */
export type UsagePeriodSegment = "day" | "week" | "month" | "7d" | "30d" | "all" | "custom";

export type UsagePeriodSelection =
  | { segment: "day"; offset: number }
  | { segment: "week"; offset: number }
  | { segment: "month"; offset: number }
  | { segment: "7d" }
  | { segment: "30d" }
  | { segment: "all" }
  | { segment: "custom"; from: string; to: string };

export type UsageSummaryPeriodKey = "today" | "last_7_days" | "last_30_days" | "all";

export interface UsageDateRange {
  from: string;
  to: string;
}

export const USAGE_PERIOD_SEGMENTS: { segment: UsagePeriodSegment; label: string; name: string }[] =
  [
    { segment: "day", label: "Day", name: "Today" },
    { segment: "week", label: "Week", name: "This week" },
    { segment: "month", label: "Month", name: "This month" },
    { segment: "7d", label: "7D", name: "Last 7 days" },
    { segment: "30d", label: "30D", name: "Last 30 days" },
    { segment: "all", label: "All", name: "All" },
    { segment: "custom", label: "Custom", name: "Custom range" },
  ];

export const DEFAULT_USAGE_PERIOD: UsagePeriodSelection = { segment: "30d" };
export const USAGE_MODEL_FOLD_LIMIT = 5;

const DAY_MS = 86_400_000;

/** How many extra models a provider group hides behind Show N more. */
export function hiddenModelCount(modelCount: number): number {
  return Math.max(0, modelCount - USAGE_MODEL_FOLD_LIMIT);
}

/** Whether this period steps one unit at a time. */
export function usagePeriodSteps(selection: UsagePeriodSelection): boolean {
  return (
    selection.segment === "day" || selection.segment === "week" || selection.segment === "month"
  );
}

export function usagePeriodFromUrl(url: URL): UsagePeriodSelection {
  const segment = url.searchParams.get("period");
  const offset = Math.max(0, Math.trunc(Number(url.searchParams.get("offset") ?? "0")) || 0);
  switch (segment) {
    case "day":
    case "week":
    case "month":
      return { segment, offset };
    case "7d":
    case "30d":
    case "all":
      return { segment };
    case "custom": {
      const from = url.searchParams.get("from");
      const to = url.searchParams.get("to");
      if (isDate(from) && isDate(to) && from <= to) return { segment: "custom", from, to };
      return DEFAULT_USAGE_PERIOD;
    }
    default:
      return DEFAULT_USAGE_PERIOD;
  }
}

export function usagePeriodHref(url: URL, selection: UsagePeriodSelection): string {
  const next = new URL(url);
  next.searchParams.set("period", selection.segment);
  next.searchParams.delete("offset");
  next.searchParams.delete("from");
  next.searchParams.delete("to");
  if (usagePeriodSteps(selection) && "offset" in selection && selection.offset > 0) {
    next.searchParams.set("offset", String(selection.offset));
  }
  if (selection.segment === "custom") {
    next.searchParams.set("from", selection.from);
    next.searchParams.set("to", selection.to);
  }
  return `${next.pathname}${next.search}${next.hash}`;
}

/** The period a segment button selects, keeping an anchored one at the current unit. */
export function usagePeriodForSegment(
  segment: UsagePeriodSegment,
  custom: UsageDateRange | null,
): UsagePeriodSelection {
  switch (segment) {
    case "day":
    case "week":
    case "month":
      return { segment, offset: 0 };
    case "custom":
      return custom
        ? { segment: "custom", from: custom.from, to: custom.to }
        : DEFAULT_USAGE_PERIOD;
    default:
      return { segment };
  }
}

/** The period one unit earlier, or null where stepping means nothing. */
export function previousUsagePeriod(selection: UsagePeriodSelection): UsagePeriodSelection | null {
  if (!usagePeriodSteps(selection) || !("offset" in selection)) return null;
  return { ...selection, offset: selection.offset + 1 };
}

/** The period one unit later. The current unit is the last: there is nothing ahead of it. */
export function nextUsagePeriod(selection: UsagePeriodSelection): UsagePeriodSelection | null {
  if (!usagePeriodSteps(selection) || !("offset" in selection) || selection.offset === 0) {
    return null;
  }
  return { ...selection, offset: selection.offset - 1 };
}

/** The four periods the Account summary carries, which are read rather than folded again. */
export function usagePeriodSummaryKey(
  selection: UsagePeriodSelection,
): UsageSummaryPeriodKey | null {
  switch (selection.segment) {
    case "day":
      return selection.offset === 0 ? "today" : null;
    case "7d":
      return "last_7_days";
    case "30d":
      return "last_30_days";
    case "all":
      return "all";
    default:
      return null;
  }
}

/** The dates this period covers in `today`'s own calendar, or null for `all`. */
export function usagePeriodRange(
  selection: UsagePeriodSelection,
  today: Date,
): UsageDateRange | null {
  switch (selection.segment) {
    case "day": {
      const day = shiftDays(startOfDay(today), -selection.offset);
      return { from: localDate(day), to: localDate(day) };
    }
    case "week": {
      const start = shiftDays(startOfWeek(today), -7 * selection.offset);
      return { from: localDate(start), to: localDate(shiftDays(start, 6)) };
    }
    case "month": {
      const start = new Date(today.getFullYear(), today.getMonth() - selection.offset, 1);
      const end = new Date(start.getFullYear(), start.getMonth() + 1, 0);
      return { from: localDate(start), to: localDate(end) };
    }
    case "7d":
      return trailing(today, 7);
    case "30d":
      return trailing(today, 30);
    case "all":
      return null;
    case "custom":
      return { from: selection.from, to: selection.to };
  }
}

/**
 * The title above the totals: the range the period covers, written for people.
 *
 * A single day is that date. A range inside one year drops the repeated year from its first
 * half. `all` has no first day, so it says so instead of naming one.
 */
export function usagePeriodTitle(selection: UsagePeriodSelection, today: Date): string {
  const range = usagePeriodRange(selection, today);
  if (!range) return "Everything kept";
  const from = parseDate(range.from);
  const to = parseDate(range.to);
  if (!from || !to) return `${range.from} – ${range.to}`;
  if (range.from === range.to) return full(from);
  return `${from.getFullYear() === to.getFullYear() ? short(from) : full(from)} – ${full(to)}`;
}

/** What the selector calls this period, which is what VoiceOver reads. */
export function usagePeriodName(selection: UsagePeriodSelection): string {
  const entry = USAGE_PERIOD_SEGMENTS.find((item) => item.segment === selection.segment);
  return entry?.name ?? "Usage period";
}

/** `YYYY-MM-DD` in this browser's own calendar. */
export function localDate(value: Date): string {
  const year = String(value.getFullYear()).padStart(4, "0");
  const month = String(value.getMonth() + 1).padStart(2, "0");
  const day = String(value.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

/** How many days a range covers, both ends included. */
export function usageRangeDays(range: UsageDateRange): number {
  const from = parseDate(range.from);
  const to = parseDate(range.to);
  if (!from || !to) return 0;
  return Math.round((to.getTime() - from.getTime()) / DAY_MS) + 1;
}

function trailing(today: Date, days: number): UsageDateRange {
  const end = startOfDay(today);
  return { from: localDate(shiftDays(end, -(days - 1))), to: localDate(end) };
}

function startOfDay(value: Date): Date {
  return new Date(value.getFullYear(), value.getMonth(), value.getDate());
}

/** Monday-first, which is how the website already draws a week. */
function startOfWeek(value: Date): Date {
  const day = startOfDay(value);
  return shiftDays(day, -((day.getDay() + 6) % 7));
}

function shiftDays(value: Date, days: number): Date {
  return new Date(value.getFullYear(), value.getMonth(), value.getDate() + days);
}

function parseDate(value: string): Date | null {
  if (!isDate(value)) return null;
  const [year, month, day] = value.split("-").map(Number);
  return new Date(year as number, (month as number) - 1, day as number);
}

function isDate(value: string | null): value is string {
  return value !== null && /^\d{4}-\d{2}-\d{2}$/.test(value);
}

function full(value: Date): string {
  return value.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

function short(value: Date): string {
  return value.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}
