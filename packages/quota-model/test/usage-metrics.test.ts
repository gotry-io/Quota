import metricsConformanceJson from "../../protocol/fixtures/usage-metrics-conformance.json" with {
  type: "json",
};
import type {
  DatedUsageRow,
  PricingCatalog,
  UsageCacheSaved,
  UsageHourOfDay,
  UsageSummaryTotals,
} from "@gotry-io/quota-protocol";
import { HOURS_OF_DAY, WEEKDAYS_OF_WEEK } from "@gotry-io/quota-protocol";
import { describe, expect, it } from "vitest";
import {
  calculateUsageCacheSaved,
  foldUsageRhythm,
  type UsageRhythmHourFact,
  usageCacheHitBasisPoints,
} from "../src/index.ts";

type MetricsConformanceFixture = {
  catalogs: Record<string, PricingCatalog>;
  rows: Record<string, DatedUsageRow>;
  hit_rate: Array<{
    name: string;
    totals: UsageSummaryTotals;
    expected_basis_points: number | null;
  }>;
  saved: Array<{
    name: string;
    /** `null` states the case where no catalog is available at all. */
    catalog: string | null;
    rows: string[];
    expected: UsageCacheSaved;
  }>;
  rhythm_cases: Array<{
    name: string;
    hours: UsageRhythmHourFact[];
    expected: {
      hours_of_day: Record<string, { total_tokens: number; cost_microusd: string | null }>;
      weekday_hours: Record<string, Record<string, number>>;
    };
  }>;
};

const fixture = metricsConformanceJson as unknown as MetricsConformanceFixture;

describe("usage metric conformance", () => {
  it("answers every cache hit rate the shared fixture names", () => {
    expect(fixture.hit_rate.length).toBeGreaterThan(1);
    for (const testCase of fixture.hit_rate) {
      expect(usageCacheHitBasisPoints(testCase.totals), testCase.name).toBe(
        testCase.expected_basis_points,
      );
    }
  });

  it("answers every cache saving the shared fixture names", () => {
    expect(fixture.saved.length).toBeGreaterThan(1);
    for (const testCase of fixture.saved) {
      const catalog = testCase.catalog === null ? null : fixture.catalogs[testCase.catalog];
      const rows = testCase.rows.map((name) => {
        const row = fixture.rows[name];
        if (!row) throw new Error(`Missing Usage row fixture ${name}.`);
        return row;
      });
      expect(calculateUsageCacheSaved(rows, catalog), testCase.name).toStrictEqual(
        testCase.expected,
      );
    }
  });

  it("answers every rhythm the shared fixture names", () => {
    expect(fixture.rhythm_cases.length).toBeGreaterThan(1);
    for (const testCase of fixture.rhythm_cases) {
      const observed = foldUsageRhythm(testCase.hours);
      expect(observed.hours_of_day, testCase.name).toStrictEqual(
        expandHoursOfDay(testCase.expected.hours_of_day),
      );
      expect(observed.weekday_hours, testCase.name).toStrictEqual(
        expandWeekdayHours(testCase.expected.weekday_hours),
      );
    }
  });
});

function expandHoursOfDay(
  named: Record<string, { total_tokens: number; cost_microusd: string | null }>,
): UsageHourOfDay[] {
  return Array.from({ length: HOURS_OF_DAY }, (_, hour) => {
    const cell = named[String(hour)];
    return {
      hour,
      total_tokens: cell?.total_tokens ?? 0,
      cost_microusd: cell?.cost_microusd ?? null,
    };
  });
}

function expandWeekdayHours(named: Record<string, Record<string, number>>): number[][] {
  return Array.from({ length: WEEKDAYS_OF_WEEK }, (_, weekday) =>
    Array.from({ length: HOURS_OF_DAY }, (_, hour) => named[String(weekday)]?.[String(hour)] ?? 0),
  );
}
