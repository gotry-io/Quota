import { describe, expect, it } from "vitest";
import {
  LOCAL_PERIOD_KEYS,
  type LocalPeriodKey,
  planLocalDateRange,
  planLocalDayWindows,
  planLocalPeriods,
} from "../src/local-periods.ts";

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

/** Whole-hour zones, sub-hour zones, and zones that skip or repeat an hour of their own. */
const zones = [
  "UTC",
  "Asia/Singapore",
  "America/Los_Angeles",
  "America/New_York",
  "Europe/London",
  "Asia/Kolkata",
  "Asia/Kathmandu",
  "Pacific/Chatham",
  "Australia/Lord_Howe",
  "America/Santiago",
  "America/Havana",
  "Pacific/Kiritimati",
  "Pacific/Niue",
];

/** Instants that sit on either side of a daylight change in one of the zones above. */
const instants = [
  "2026-08-26T02:00:00Z",
  "2026-01-15T23:30:00Z",
  "2026-03-08T11:00:00Z",
  "2026-09-06T05:00:00Z",
  "2026-11-01T04:30:00Z",
  "2026-10-04T15:00:00Z",
];

describe("local periods", () => {
  it("covers exactly the hours the caller's calendar puts in each period, once each", () => {
    for (const zone of zones) {
      for (const text of instants) {
        const checkedAt = new Date(text);
        const plan = planLocalPeriods(zone, checkedAt);
        for (const key of LOCAL_PERIOD_KEYS) {
          expect(folded(plan, key), `${zone} ${text} ${key}`).toEqual(expected(zone, plan, key));
        }
      }
    }
  });

  it("reads a handful of UTC days, whatever the caller's offset", () => {
    for (const zone of zones) {
      for (const text of instants) {
        const plan = planLocalPeriods(zone, new Date(text));
        const dates = new Set<string>();
        for (const edge of plan.boundaries) {
          for (
            let hour = Date.parse(edge.range.from);
            hour < Date.parse(edge.range.to);
            hour += HOUR
          ) {
            dates.add(instant(hour).slice(0, 10));
          }
        }
        // The three periods share an end, so the edges are three starts and one end. A period
        // with no whole UTC day inside it reads both of the days it touches.
        expect(dates.size, `${zone} ${text}`).toBeLessThanOrEqual(5);
        expect(plan.boundaries.every((edge) => edge.periods.length > 0)).toBe(true);
      }
    }
  });

  it("asks for no hour at all when the caller keeps UTC", () => {
    const plan = planLocalPeriods("UTC", new Date("2026-08-26T02:00:00Z"));
    expect(plan.boundaries).toEqual([]);
    expect(plan.localDate).toBe("2026-08-26");
    expect(plan.days).toEqual({
      today: { from: "2026-08-26", to: "2026-08-26" },
      last_7_days: { from: "2026-08-20", to: "2026-08-26" },
      last_30_days: { from: "2026-07-28", to: "2026-08-26" },
    });
  });

  it("keeps a period whole across a daylight change, a skipped midnight, and a half hour", () => {
    // A local day is not always twenty-four hours long, and its midnight does not always exist.
    // Each case names the zone's own event, the local date the read lands on, and how many whole
    // UTC hours each period covers because of it.
    const cases = [
      {
        // Chile springs forward at midnight, so 6 September has no 00:00 at all: the day begins
        // at the first hour the zone reads as that date.
        zone: "America/Santiago",
        checkedAt: "2026-09-06T05:00:00Z",
        localDate: "2026-09-06",
        todayStartsAt: "2026-09-06T04:00:00Z",
        hours: { today: 23, last_7_days: 167, last_30_days: 719 },
      },
      {
        // The clock falls back at 02:00, so 1 November is twenty-five hours long and one wall
        // clock hour happens twice. Neither copy may be counted twice or dropped.
        zone: "America/New_York",
        checkedAt: "2026-11-01T12:00:00Z",
        localDate: "2026-11-01",
        todayStartsAt: "2026-11-01T04:00:00Z",
        hours: { today: 25, last_7_days: 169, last_30_days: 721 },
      },
      {
        // Lord Howe moves by half an hour, on 4 October. An hour is the finest fact stored, so
        // that day is twenty-three whole hours rather than twenty-three and a half.
        zone: "Australia/Lord_Howe",
        checkedAt: "2026-10-04T15:00:00Z",
        localDate: "2026-10-05",
        todayStartsAt: "2026-10-04T13:00:00Z",
        hours: { today: 24, last_7_days: 167, last_30_days: 719 },
      },
      {
        // Chatham reads 12:45 ahead and moved an hour on 27 September, which is inside thirty
        // local days of this read and outside seven.
        zone: "Pacific/Chatham",
        checkedAt: "2026-10-04T15:00:00Z",
        localDate: "2026-10-05",
        todayStartsAt: "2026-10-04T11:00:00Z",
        hours: { today: 24, last_7_days: 168, last_30_days: 719 },
      },
      {
        // Kathmandu reads 5:45 ahead and never moves, so only the rounding is in play.
        zone: "Asia/Kathmandu",
        checkedAt: "2026-08-26T02:00:00Z",
        localDate: "2026-08-26",
        todayStartsAt: "2026-08-25T19:00:00Z",
        hours: { today: 24, last_7_days: 168, last_30_days: 720 },
      },
    ] as const;

    for (const item of cases) {
      const plan = planLocalPeriods(item.zone, new Date(item.checkedAt));
      expect(plan.localDate, item.zone).toBe(item.localDate);
      for (const key of LOCAL_PERIOD_KEYS) {
        // `folded` fails on its own if a period counts one hour twice; matching what the zone's
        // calendar puts in the period is what says no hour is missing either.
        const hours = folded(plan, key);
        expect(hours, `${item.zone} ${key}`).toEqual(expected(item.zone, plan, key));
        expect(hours.length, `${item.zone} ${key} hour count`).toBe(item.hours[key]);
      }
      expect(folded(plan, "today")[0], item.zone).toBe(item.todayStartsAt);
      // Each period contains the one inside it, whole.
      const seven = new Set(folded(plan, "last_7_days"));
      const thirty = new Set(folded(plan, "last_30_days"));
      expect(
        folded(plan, "today").every((hour) => seven.has(hour)),
        item.zone,
      ).toBe(true);
      expect(
        [...seven].every((hour) => thirty.has(hour)),
        item.zone,
      ).toBe(true);
    }
  });

  it("derives each summary preset from the same explicit local-date range", () => {
    for (const zone of zones) {
      for (const text of instants) {
        const plan = planLocalPeriods(zone, new Date(text));
        const today = planLocalDateRange(zone, plan.localDate, plan.localDate);
        const seven = planLocalDateRange(zone, shiftLocal(plan.localDate, -6), plan.localDate);
        const thirty = planLocalDateRange(zone, shiftLocal(plan.localDate, -29), plan.localDate);
        expect(hoursInRange(today), `${zone} ${text} today`).toEqual(folded(plan, "today"));
        expect(hoursInRange(seven), `${zone} ${text} last_7_days`).toEqual(
          folded(plan, "last_7_days"),
        );
        expect(hoursInRange(thirty), `${zone} ${text} last_30_days`).toEqual(
          folded(plan, "last_30_days"),
        );
      }
    }
  });

  it("tiles an inclusive local-date range into adjacent hour-grid windows", () => {
    const plan = planLocalDateRange("Asia/Kolkata", "2026-08-25", "2026-08-26");
    const windows = planLocalDayWindows("Asia/Kolkata", "2026-08-25", "2026-08-26");
    expect(windows).toEqual([
      { date: "2026-08-25", start: "2026-08-24T19:00:00Z", end: "2026-08-25T19:00:00Z" },
      { date: "2026-08-26", start: "2026-08-25T19:00:00Z", end: "2026-08-26T19:00:00Z" },
    ]);
    expect(windows[0]?.start).toBe(plan.start);
    expect(windows[1]?.end).toBe(plan.end);
    expect(windows[0]?.end).toBe(windows[1]?.start);
    const hours = windows.flatMap((window) => {
      const span: string[] = [];
      for (let hour = Date.parse(window.start); hour < Date.parse(window.end); hour += HOUR) {
        span.push(instant(hour));
      }
      return span;
    });
    expect(new Set(hours).size).toBe(hours.length);
    expect(hours[0]).toBe(plan.start);
    expect(hours.at(-1)).toBe("2026-08-26T18:00:00Z");
    expect(hours).toContain("2026-08-25T18:00:00Z");
    expect(hours.filter((hour) => hour === "2026-08-25T18:00:00Z")).toHaveLength(1);
  });
});

/** The hours a plan actually folds into one period, from the rollup and from the boundaries. */
function folded(plan: ReturnType<typeof planLocalPeriods>, key: LocalPeriodKey): string[] {
  const hours: string[] = [];
  const window = plan.days[key];
  if (window) {
    for (
      let day = Date.parse(`${window.from}T00:00:00Z`);
      day <= Date.parse(`${window.to}T00:00:00Z`);
      day += DAY
    ) {
      for (let hour = day; hour < day + DAY; hour += HOUR) hours.push(instant(hour));
    }
  }
  for (const edge of plan.boundaries) {
    if (!edge.periods.includes(key)) continue;
    for (let hour = Date.parse(edge.range.from); hour < Date.parse(edge.range.to); hour += HOUR) {
      hours.push(instant(hour));
    }
  }
  expect(new Set(hours).size, `${key} counts an hour twice`).toBe(hours.length);
  return hours.sort();
}

/** The hours whose local date the caller's calendar puts inside the period, counted directly. */
function expected(
  zone: string,
  plan: ReturnType<typeof planLocalPeriods>,
  key: LocalPeriodKey,
): string[] {
  const clock = new Intl.DateTimeFormat("en-CA", { timeZone: zone });
  const last = plan.localDate;
  const first = new Date(Date.parse(`${last}T00:00:00Z`) - reach(key) * DAY)
    .toISOString()
    .slice(0, 10);
  const hours: string[] = [];
  const from = Date.parse(`${first}T00:00:00Z`) - 2 * DAY;
  for (let hour = from; hour <= Date.parse(`${last}T00:00:00Z`) + 2 * DAY; hour += HOUR) {
    const date = clock.format(hour);
    if (date >= first && date <= last) hours.push(instant(hour));
  }
  return hours.sort();
}

function hoursInRange(plan: ReturnType<typeof planLocalDateRange>): string[] {
  const hours: string[] = [];
  if (plan.days) {
    for (
      let day = Date.parse(`${plan.days.from}T00:00:00Z`);
      day <= Date.parse(`${plan.days.to}T00:00:00Z`);
      day += DAY
    ) {
      for (let hour = day; hour < day + DAY; hour += HOUR) hours.push(instant(hour));
    }
  }
  for (const edge of plan.boundaries) {
    for (let hour = Date.parse(edge.from); hour < Date.parse(edge.to); hour += HOUR) {
      hours.push(instant(hour));
    }
  }
  expect(new Set(hours).size, "range counts an hour twice").toBe(hours.length);
  return hours.sort();
}

function shiftLocal(date: string, days: number): string {
  return new Date(Date.parse(`${date}T00:00:00Z`) + days * DAY).toISOString().slice(0, 10);
}

function reach(key: LocalPeriodKey): number {
  return key === "today" ? 0 : key === "last_7_days" ? 6 : 29;
}

function instant(value: number): string {
  return `${new Date(value).toISOString().slice(0, 19)}Z`;
}
