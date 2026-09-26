/**
 * Which period the Usage page is showing, and how the URL carries it.
 *
 * Three periods are anchored to this browser's own calendar and step: a day, a week, and a month,
 * each an offset back from the current one. Three are trailing windows (the website adds the last
 * 90 days to the two the Account summary folds), `all` is everything retained, and `custom` is a
 * range someone picked. The phrases are in `docs/design.md` Shared product vocabulary.
 *
 * Every selection except `all` is `GET /api/v6/account/usage/period` with these inclusive local
 * dates and the browser's IANA timezone. Presets are the same read. `all` stays the summary's
 * 730 UTC-day window. The year activity heatmap still reads the activity route.
 */
export type UsagePeriodSegment = "day" | "week" | "month" | "7d" | "30d" | "90d" | "all" | "custom";

export type UsagePeriodSelection =
  | { segment: "day"; offset: number }
  | { segment: "week"; offset: number }
  | { segment: "month"; offset: number }
  | { segment: "7d" }
  | { segment: "30d" }
  | { segment: "90d" }
  | { segment: "all" }
  | { segment: "custom"; from: string; to: string };

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
    { segment: "90d", label: "90D", name: "Last 90 days" },
    { segment: "all", label: "All", name: "All" },
    { segment: "custom", label: "Custom", name: "Custom range" },
  ];

/** The periods the control shows as segments; the rest sit under **More**. */
export const USAGE_PERIOD_PRIMARY: readonly UsagePeriodSegment[] = ["day", "7d", "30d", "90d"];
export const USAGE_PERIOD_MORE: readonly UsagePeriodSegment[] = ["week", "month", "all", "custom"];

export const DEFAULT_USAGE_PERIOD: UsagePeriodSelection = { segment: "30d" };

const DAY_MS = 86_400_000;

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
    case "90d":
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

/** Whether the Usage page takes this selection from the summary instead of the period read. */
export function usagePeriodReadsFromSummary(selection: UsagePeriodSelection): boolean {
  return selection.segment === "all";
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
    case "90d":
      return trailing(today, 90);
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

/**
 * The equal range just before this period, which the page compares against, or null for `all`
 * and a custom range. A trailing window shifts back by its length. A day, week, or month steps
 * back one unit; the current unit is still running, so it is compared with the same number of
 * days at the start of the one before (this week so far against the same days last week).
 */
export function previousUsagePeriodRange(
  selection: UsagePeriodSelection,
  today: Date,
): UsageDateRange | null {
  switch (selection.segment) {
    case "7d":
    case "30d":
    case "90d": {
      const days = selection.segment === "7d" ? 7 : selection.segment === "30d" ? 30 : 90;
      const end = shiftDays(startOfDay(today), -days);
      return { from: localDate(shiftDays(end, -(days - 1))), to: localDate(end) };
    }
    case "day":
    case "week":
    case "month": {
      const previous = usagePeriodRange({ ...selection, offset: selection.offset + 1 }, today);
      const current = usagePeriodRange(selection, today);
      if (!previous || !current) return null;
      if (selection.offset > 0) return previous;
      const elapsed = usageRangeDays({ from: current.from, to: localDate(startOfDay(today)) });
      const start = parseDate(previous.from);
      if (!start) return null;
      const to = localDate(shiftDays(start, elapsed - 1));
      return { from: previous.from, to: to < previous.to ? to : previous.to };
    }
    default:
      return null;
  }
}

/** What the comparison is against, in the words of the meta line: `previous 30 days`. */
export function previousUsagePeriodName(selection: UsagePeriodSelection): string | null {
  switch (selection.segment) {
    case "7d":
      return "previous 7 days";
    case "30d":
      return "previous 30 days";
    case "90d":
      return "previous 90 days";
    case "day":
      return selection.offset === 0 ? "yesterday" : "the day before";
    case "week":
      return selection.offset === 0 ? "the same days last week" : "the week before";
    case "month":
      return selection.offset === 0 ? "the same days last month" : "the month before";
    default:
      return null;
  }
}

/**
 * The period as the end of a sentence: `in the last 30 days`, `today so far`, `this week`.
 * A stepped-back or custom period names its dates.
 */
export function usagePeriodPhrase(selection: UsagePeriodSelection, today: Date): string {
  switch (selection.segment) {
    case "7d":
      return "in the last 7 days";
    case "30d":
      return "in the last 30 days";
    case "90d":
      return "in the last 90 days";
    case "all":
      return "across everything kept";
    case "day":
      if (selection.offset === 0) return "today so far";
      break;
    case "week":
      if (selection.offset === 0) return "this week";
      break;
    case "month":
      if (selection.offset === 0) return "this month";
      break;
  }
  const range = usagePeriodRange(selection, today);
  if (range && range.from === range.to) return `on ${usagePeriodTitle(selection, today)}`;
  return `from ${usagePeriodTitle(selection, today).replace(" – ", " to ")}`;
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
  return value.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

function short(value: Date): string {
  return value.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}
