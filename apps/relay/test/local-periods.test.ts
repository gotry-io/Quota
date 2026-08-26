import { describe, expect, it } from "vitest";
import { LOCAL_PERIOD_KEYS, type LocalPeriodKey, planLocalPeriods } from "../src/local-periods.ts";

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

/** Whole-hour zones, sub-hour zones, and zones that skip or repeat an hour of their own. */
const zones = [
  "UTC",
  "Asia/Singapore",
  "America/Los_Angeles",
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

  it("cuts the UTC day at local midnight for a caller eight hours ahead", () => {
    const plan = planLocalPeriods("Asia/Singapore", new Date("2026-08-26T02:00:00Z"));
    expect(plan.localDate).toBe("2026-08-26");
    // Today has no UTC day wholly inside it, so it is read entirely from the two days it cuts.
    expect(plan.days.today).toBeNull();
    expect(plan.days.last_7_days).toEqual({ from: "2026-08-20", to: "2026-08-25" });
    expect(plan.days.last_30_days).toEqual({ from: "2026-07-28", to: "2026-08-25" });
    // The wider two share the hours of 26 August that have happened, and each cuts its own
    // first day out of the day before it.
    expect(plan.boundaries).toEqual([
      {
        range: { from: "2026-08-25T16:00:00Z", to: "2026-08-26T16:00:00Z" },
        periods: ["today"],
      },
      {
        range: { from: "2026-08-19T16:00:00Z", to: "2026-08-20T00:00:00Z" },
        periods: ["last_7_days"],
      },
      {
        range: { from: "2026-08-26T00:00:00Z", to: "2026-08-26T16:00:00Z" },
        periods: ["last_7_days", "last_30_days"],
      },
      {
        range: { from: "2026-07-27T16:00:00Z", to: "2026-07-28T00:00:00Z" },
        periods: ["last_30_days"],
      },
    ]);
  });

  it("rounds a sub-hour offset up, so no hour lands in two periods", () => {
    // Kolkata reads 05:30 ahead, so its midnight falls inside the hour beginning 18:00 UTC. That
    // hour is reported with the day before it rather than split, at either edge of the day.
    const plan = planLocalPeriods("Asia/Kolkata", new Date("2026-08-26T02:00:00Z"));
    expect(plan.boundaries[0]?.range).toEqual({
      from: "2026-08-25T19:00:00Z",
      to: "2026-08-26T19:00:00Z",
    });
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

function reach(key: LocalPeriodKey): number {
  return key === "today" ? 0 : key === "last_7_days" ? 6 : 29;
}

function instant(value: number): string {
  return `${new Date(value).toISOString().slice(0, 19)}Z`;
}
