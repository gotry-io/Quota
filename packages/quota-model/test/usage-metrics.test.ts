import metricsConformanceJson from "../../protocol/fixtures/usage-metrics-conformance.json" with {
  type: "json",
};
import type {
  DatedUsageRow,
  PricingCatalog,
  UsageCacheSaved,
  UsageSummaryTotals,
} from "@gotry-io/quota-protocol";
import { describe, expect, it } from "vitest";
import { calculateUsageCacheSaved, usageCacheHitBasisPoints } from "../src/index.ts";

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
});
