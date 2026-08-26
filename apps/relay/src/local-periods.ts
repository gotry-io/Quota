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

/** Hours that no period's rollup covers, and the periods that have to fold them one by one. */
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
 * end together, so the edges are the three starts and the one shared end: at most four UTC days
 * of hourly rows, against the thirty-one daily rows the widest period folds.
 */
export interface LocalPeriodPlan {
  /** The caller's calendar date, which is when this answer turns over with no write behind it. */
  localDate: string;
  /** The whole UTC days each period folds, or null when its edges cut every day it touches. */
  days: Record<LocalPeriodKey, UsageDateWindow | null>;
  /** Disjoint hour ranges, each tagged with the periods that no rollup row already covers. */
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

  const starts = {} as Record<LocalPeriodKey, number>;
  const days = {} as Record<LocalPeriodKey, UsageDateWindow | null>;
  const cuts: { from: number; to: number }[] = [];
  for (const key of LOCAL_PERIOD_KEYS) {
    const start = startOfLocalHour(clock, shiftDate(localDate, -daysBack[key]));
    starts[key] = start;
    const firstWhole = ceilDay(start);
    const lastWholeEnd = floorDay(end);
    days[key] =
      firstWhole < lastWholeEnd
        ? { from: utcDate(firstWhole), to: utcDate(lastWholeEnd - DAY) }
        : null;
    const head = Math.min(firstWhole, end);
    if (start < head) cuts.push({ from: start, to: head });
  }
  const lastMidnight = floorDay(end);
  if (lastMidnight < end && lastMidnight >= starts.today) {
    cuts.push({ from: lastMidnight, to: end });
  }

  return {
    localDate,
    days,
    // A period folds a cut only when the cut is inside it and outside the days it rolls up, so
    // every instant a period covers is counted once: from the rollup, or from these hours.
    boundaries: cuts.map((cut) => ({
      range: { from: utcHour(cut.from), to: utcHour(cut.to) },
      periods: LOCAL_PERIOD_KEYS.filter(
        (key) => cut.from >= starts[key] && !covers(days[key], utcDate(cut.from)),
      ),
    })),
  };
}

function covers(window: UsageDateWindow | null, date: string): boolean {
  return window !== null && date >= window.from && date <= window.to;
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
