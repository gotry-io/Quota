import conformanceJson from "../fixtures/usage-period-conformance.json" with { type: "json" };
import { describe, expect, it } from "vitest";
import {
  IanaTimezoneSchema,
  MAXIMUM_USAGE_PERIOD_DAYS,
  USAGE_HOUR_GRID_RULE,
  USAGE_MODEL_SERIES_LIMIT,
  UsagePeriodRangeSchema,
} from "../src/index.ts";

type Expected = {
  bounds?: { start: string; end: string };
  day_dates?: string[];
  totals?: { messages: number };
};

type Case = {
  name: string;
  checked_at: string;
  timezone: string;
  from?: string;
  to?: string;
  expected?: Expected;
  summary_presets?: Array<{ from: string; to: string; expected: Expected }>;
  reads?: Array<{ from: string; to: string; expected: Expected }>;
  adjacent?: { from: string; to: string };
};

const conformance = conformanceJson as unknown as {
  hour_grid_rule: string;
  maximum_local_days: number;
  model_series_limit: number;
  cases: Case[];
};

const required = [
  "preset_equals_custom",
  "adjacent_no_overlap",
  "missing_is_not_zero",
  "dst_forward",
  "dst_back",
  "offset_plus_0530",
  "offset_plus_0545",
  "offset_minus_0330",
  "deletion",
  "retention_edge",
  "series_top_n_and_other",
  "series_merges_agents",
  "series_agent_scoped_alias",
  "series_dst_back",
] as const;

/**
 * The period fixture is answered by Relay as producer. This file states its shape so a consumer
 * can adopt the same vectors later without guessing which cases exist.
 */
describe("usage period conformance", () => {
  it("names the hour-grid rule and every required case", () => {
    expect(conformance.hour_grid_rule).toBe(USAGE_HOUR_GRID_RULE);
    expect(conformance.maximum_local_days).toBe(MAXIMUM_USAGE_PERIOD_DAYS);
    expect(conformance.model_series_limit).toBe(USAGE_MODEL_SERIES_LIMIT);
    expect(conformance.cases.map((testCase) => testCase.name)).toEqual([...required]);
  });

  it("places every range on a real calendar in a real IANA zone", () => {
    for (const testCase of conformance.cases) {
      expect(IanaTimezoneSchema.safeParse(testCase.timezone).success, testCase.name).toBe(true);
      expect(Date.parse(testCase.checked_at), testCase.name).not.toBeNaN();
      const ranges = [
        ...(testCase.from && testCase.to ? [{ from: testCase.from, to: testCase.to }] : []),
        ...(testCase.adjacent ? [testCase.adjacent] : []),
        ...(testCase.summary_presets ?? []),
        ...(testCase.reads ?? []),
      ];
      expect(ranges.length, testCase.name).toBeGreaterThan(0);
      for (const range of ranges) {
        expect(
          UsagePeriodRangeSchema.safeParse({
            from: range.from,
            to: range.to,
            timezone: testCase.timezone,
          }).success,
          `${testCase.name} ${range.from}..${range.to}`,
        ).toBe(true);
      }
      for (const expected of [
        testCase.expected,
        ...(testCase.summary_presets ?? []).map((item) => item.expected),
        ...(testCase.reads ?? []).map((item) => item.expected),
      ]) {
        if (!expected?.bounds) continue;
        expect(expected.bounds.start < expected.bounds.end, testCase.name).toBe(true);
        if (expected.day_dates) {
          for (const date of expected.day_dates) {
            expect(/^\d{4}-\d{2}-\d{2}$/.test(date), `${testCase.name} ${date}`).toBe(true);
          }
        }
      }
    }
  });
});
