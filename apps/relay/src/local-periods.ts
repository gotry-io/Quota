import type { UsageHourRange } from "@gotry-io/relay-core";

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

export function planLocalPeriods(timezone: string, checkedAt: Date): LocalPeriodPlan {
  const clock = new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  const localDate = localDateAt(clock, checkedAt.getTime());
  const end = startOfLocalHour(clock, shiftDate(localDate, 1));
  const days = {} as Record<LocalPeriodKey, UsageDateWindow | null>;
  const boundaries: UsageBoundary[] = [];

  for (const key of LOCAL_PERIOD_KEYS) {
    const start = startOfLocalHour(clock, shiftDate(localDate, -daysBack[key]));
    const firstWhole = ceilDay(start);
    const lastWholeEnd = floorDay(end);
    if (firstWhole < lastWholeEnd) {
      // The rollup answers the days between the two edges; the edges themselves are hours.
      days[key] = { from: utcDate(firstWhole), to: utcDate(lastWholeEnd - DAY) };
      cut(boundaries, key, start, firstWhole);
      cut(boundaries, key, lastWholeEnd, end);
    } else {
      // No UTC day lies wholly inside, so this period is read hour by hour end to end.
      days[key] = null;
      cut(boundaries, key, start, end);
    }
  }
  return { localDate, days, boundaries };
}

/**
 * Record that one period folds the hours in `[from, to)`.
 *
 * What a period folds is its own rollup days plus its own cuts, which together are exactly the
 * instants it covers, each once. Two periods asking for the same hours share one read; two
 * asking for overlapping but different ones do not, because neither is counting the other's.
 */
function cut(boundaries: UsageBoundary[], key: LocalPeriodKey, from: number, to: number): void {
  if (from >= to) return;
  const range = { from: utcHour(from), to: utcHour(to) };
  const shared = boundaries.find(
    (edge) => edge.range.from === range.from && edge.range.to === range.to,
  );
  if (shared) shared.periods.push(key);
  else boundaries.push({ range, periods: [key] });
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

/** A whole hour in the text `usage_hourly` keys it by. */
function utcHour(instant: number): string {
  return `${new Date(instant).toISOString().slice(0, 19)}Z`;
}
