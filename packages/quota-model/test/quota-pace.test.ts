import conformanceJson from "../../protocol/fixtures/quota-pace-conformance.json" with {
  type: "json",
};
import { describe, expect, it } from "vitest";
import { type QuotaPace, quotaPace } from "../src/index.ts";

type PaceCase = {
  name: string;
  now: string;
  window: {
    id: string;
    title: string;
    used_percent: number;
    resets_at?: string;
    duration_seconds?: number;
    remaining_value?: number;
    limit_value?: number;
    value_unit?: string;
  };
  expected: QuotaPace;
  expected_copy: string | null;
};

const fixture = conformanceJson as unknown as { cases: PaceCase[] };

describe("quotaPace", () => {
  it("answers every case in the shared conformance fixture", () => {
    expect(fixture.cases.length).toBeGreaterThanOrEqual(12);
    for (const testCase of fixture.cases) {
      const pace = quotaPace(testCase.window, new Date(testCase.now));
      expect(pace, testCase.name).toEqual(testCase.expected);
    }
  });

  it("states no pace for a window whose reset instant cannot be placed", () => {
    const pace = quotaPace(
      { used_percent: 50, resets_at: "not a time", duration_seconds: 18_000 },
      new Date("2026-09-05T09:30:00Z"),
    );
    expect(pace).toEqual({ kind: "none" });
  });
});
