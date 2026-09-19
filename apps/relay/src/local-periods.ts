import type { UsageHourRange, UsageLocalDayWindow } from "@gotry-io/relay-core";

/** The three periods an Account read answers against the caller's calendar. */
export const LOCAL_PERIOD_KEYS = ["today", "last_7_days", "last_30_days"] as const;
export type LocalPeriodKey = (typeof LOCAL_PERIOD_KEYS)[number];

/** How many local days before today each period reaches back. */
const daysBack: Record<LocalPeriodKey, number> = { today: 0, last_7_days: 6, last_30_days: 29 };

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

/** Inclusive UTC dates. */
export interface UsageDateWindow {
  from: string;
  to: string;
}

/** Hours a period's rollup does not cover, and the periods that have to fold them one by one. */
export interface UsageBoundary {
  range: UsageHourRange;
  periods: LocalPeriodKey[];
}

/**
 * How to answer the three local periods without opening the hourly history.
 *
 * A local day begins at local midnight, so a period is a half-open range of instants rather than
 * a run of UTC dates. Every UTC day that lies wholly inside such a range still comes from
 * `usage_daily`; only the day at each edge has to be read an hour at a time. The three periods
 * end together, so the edges are three starts and one shared end: a handful of UTC days of hourly
 * rows, against the thirty-one daily rows the widest period folds.
 */
export interface LocalPeriodPlan {
  /** The caller's calendar date, which is when this answer turns over with no write behind it. */
  localDate: string;
  /** The whole UTC days each period folds, or null when its edges cut every day it touches. */
  days: Record<LocalPeriodKey, UsageDateWindow | null>;
  /** The hour ranges to read, each tagged with the periods that fold what it answers. */
  boundaries: UsageBoundary[];
}

/**
 * How to answer one inclusive local-date range without opening the hourly history for its
 * interior UTC days.
 *
 * `start` is the first whole UTC hour whose civil date in `timezone` is `from`. `end` is the
 * first whole UTC hour of the day after `to`. Whole UTC days strictly inside `[start, end)`
 * come from `usage_daily`; the hours the two edges cut come from `usage_hourly`.
 */
export interface LocalDateRangePlan {
  start: string;
  end: string;
  days: UsageDateWindow | null;
  boundaries: UsageHourRange[];
}

export function planLocalDateRange(timezone: string, from: string, to: string): LocalDateRangePlan {
  const clock = zoneClock(timezone);
  const start = startOfLocalHour(clock, from);
  const end = startOfLocalHour(clock, shiftDate(to, 1));
  const firstWhole = ceilDay(start);
  const lastWholeEnd = floorDay(end);
  if (firstWhole < lastWholeEnd) {
    const boundaries: UsageHourRange[] = [];
    if (start < firstWhole) boundaries.push({ from: utcHour(start), to: utcHour(firstWhole) });
    if (lastWholeEnd < end) {
      boundaries.push({ from: utcHour(lastWholeEnd), to: utcHour(end) });
    }
    return {
      start: utcHour(start),
      end: utcHour(end),
      days: { from: utcDate(firstWhole), to: utcDate(lastWholeEnd - DAY) },
      boundaries,
    };
  }
  return {
    start: utcHour(start),
    end: utcHour(end),
    days: null,
    boundaries: start < end ? [{ from: utcHour(start), to: utcHour(end) }] : [],
  };
}

/**
 * One hour-grid window per inclusive local date in `[from, to]`.
 *
 * Adjacent windows share an endpoint and no hour: `windows[i].end === windows[i + 1].start`.
 * A 366-day period therefore names 366 spans, at most 367 including a spare the contract
 * would refuse. The period read JOINs `usage_hourly` onto this table rather than scanning
 * hour-identity rows into JS.
 */
export function planLocalDayWindows(
  timezone: string,
  from: string,
  to: string,
): UsageLocalDayWindow[] {
  const clock = zoneClock(timezone);
  const windows: UsageLocalDayWindow[] = [];
  let date = from;
  let start = startOfLocalHour(clock, date);
  while (date <= to) {
    const next = shiftDate(date, 1);
    const end = startOfLocalHour(clock, next);
    windows.push({ date, start: utcHour(start), end: utcHour(end) });
    date = next;
    start = end;
  }
  return windows;
}

export function planLocalPeriods(timezone: string, checkedAt: Date): LocalPeriodPlan {
  const clock = zoneClock(timezone);
  const localDate = localDateAt(clock, checkedAt.getTime());
  const days = {} as Record<LocalPeriodKey, UsageDateWindow | null>;
  const boundaries: UsageBoundary[] = [];

  for (const key of LOCAL_PERIOD_KEYS) {
    const range = planLocalDateRange(timezone, shiftDate(localDate, -daysBack[key]), localDate);
    days[key] = range.days;
    for (const edge of range.boundaries) {
      const shared = boundaries.find(
        (item) => item.range.from === edge.from && item.range.to === edge.to,
      );
      if (shared) shared.periods.push(key);
      else boundaries.push({ range: edge, periods: [key] });
    }
  }
  return { localDate, days, boundaries };
}

function zoneClock(timezone: string): Intl.DateTimeFormat {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

/**
 * The first whole UTC hour a local date claims.
 *
 * An hour is the finest fact Relay stores, so a zone offset by less than an hour reports the
 * hour its local midnight falls in with the day before it. The alternative is to count that hour
 * twice, and no period may overlap the one beside it.
 *
 * The offset at the answer is not always the offset at the guess, and a zone that skipped or
 * repeated its own midnight has none that lands. Walking the hour grid from the guess settles
 * all three the same way: the day starts at the first hour the zone reads as that date.
 */
function startOfLocalHour(clock: Intl.DateTimeFormat, date: string): number {
  const wall = Date.parse(`${date}T00:00:00Z`);
  const guess = wall - (wallClock(clock, wall) - wall);
  let hour = Math.ceil((wall - (wallClock(clock, guess) - guess)) / HOUR) * HOUR;
  while (localDateAt(clock, hour - HOUR) >= date) hour -= HOUR;
  while (localDateAt(clock, hour) < date) hour += HOUR;
  return hour;
}

function localDateAt(clock: Intl.DateTimeFormat, instant: number): string {
  return utcDate(wallClock(clock, instant));
}

/** The wall clock a zone shows at an instant, as that reading taken for a UTC one. */
function wallClock(clock: Intl.DateTimeFormat, instant: number): number {
  const parts = clock.formatToParts(instant);
  const field = (type: Intl.DateTimeFormatPartTypes) =>
    Number(parts.find((part) => part.type === type)?.value);
  return Date.UTC(
    field("year"),
    field("month") - 1,
    field("day"),
    field("hour"),
    field("minute"),
    field("second"),
  );
}

function shiftDate(date: string, days: number): string {
  return utcDate(Date.parse(`${date}T00:00:00Z`) + days * DAY);
}

function ceilDay(instant: number): number {
  return Math.ceil(instant / DAY) * DAY;
}

function floorDay(instant: number): number {
  return Math.floor(instant / DAY) * DAY;
}

function utcDate(instant: number): string {
  return new Date(instant).toISOString().slice(0, 10);
}

const weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;

/**
 * The caller's clock at a stored UTC hour: civil date, hour of day, Sunday-first weekday.
 */
export function localClockAt(
  timezone: string,
  bucketStartUtc: string,
): { date: string; hour: number; weekday: number } {
  const clock = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    weekday: "short",
  });
  const parts = clock.formatToParts(new Date(bucketStartUtc));
  const field = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((part) => part.type === type)?.value ?? "";
  const month = field("month").padStart(2, "0");
  const day = field("day").padStart(2, "0");
  const weekdayName = field("weekday");
  const weekday = weekdayNames.indexOf(weekdayName as (typeof weekdayNames)[number]);
  return {
    date: `${field("year")}-${month}-${day}`,
    hour: Number(field("hour")),
    weekday: weekday < 0 ? 0 : weekday,
  };
}

/** A whole hour in the text `usage_hourly` keys it by. */
function utcHour(instant: number): string {
  return `${new Date(instant).toISOString().slice(0, 19)}Z`;
}
