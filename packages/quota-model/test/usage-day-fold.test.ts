import conformanceJson from "../../protocol/fixtures/usage-day-fold-conformance.json" with {
  type: "json",
};
import { describe, expect, it } from "vitest";
import { foldUsageActivityDays } from "../src/index.ts";

type FoldFixture = {
  cases: Array<{
    name: string;
    from: string;
    to: string;
    days: Parameters<typeof foldUsageActivityDays>[0];
    expected: { totals: unknown; cost: unknown; partial: boolean };
  }>;
};

const fixture = conformanceJson as unknown as FoldFixture;

/**
 * Both Apple apps fold the same days into the same period. All of them answer this file, so a
 * client that starts adding a range up differently cannot do it quietly.
 */
describe("usage day fold conformance", () => {
  it("answers every case in the shared fixture", () => {
    expect(fixture.cases.length).toBeGreaterThanOrEqual(6);
    for (const testCase of fixture.cases) {
      const folded = foldUsageActivityDays(testCase.days, { from: testCase.from, to: testCase.to });
      expect(folded.totals, testCase.name).toEqual(testCase.expected.totals);
      expect(folded.cost, testCase.name).toEqual(testCase.expected.cost);
      expect(folded.partial, testCase.name).toEqual(testCase.expected.partial);
      expect(folded.agents, testCase.name).toEqual([]);
    }
  });
});
