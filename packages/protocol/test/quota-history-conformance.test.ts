import conformanceJson from "../fixtures/quota-history-conformance.json" with { type: "json" };
import { describe, expect, it } from "vitest";
import { QuotaSnapshotSchema, Rfc3339InstantSchema } from "../src/index.ts";

type HistoryPoint = { elapsed_fraction: number; used_percent: number };

type HistoryCase = {
  name: string;
  now: string;
  utc_offset_seconds: number;
  window: unknown;
  samples: { resets_at: string; observed_at: string; used_percent: number }[];
  expected: {
    points: HistoryPoint[];
    projection: HistoryPoint | null;
    windows_today: {
      started_at: string;
      resets_at: string;
      peak_used_percent: number;
      is_current: boolean;
    }[];
  } | null;
};

const conformance = conformanceJson as unknown as {
  decimation_seconds: number;
  retention_days: number;
  cases: HistoryCase[];
};

/**
 * The history fixture is read by two runtimes that do not share a type checker, so this file
 * is where its shape is stated: every case names a real quota window, samples that could have
 * been stored beside it, and a fold the rule can produce. What the rule answers is
 * `packages/service`'s and `packages/apple-shared`'s test against this same file.
 */
describe("quota history conformance", () => {
  it("states enough cases to pin the fold", () => {
    expect(conformance.cases.length).toBeGreaterThanOrEqual(8);
    expect(conformance.decimation_seconds).toBe(300);
    expect(conformance.retention_days).toBe(30);
  });

  it("names a real quota window, a placeable clock, and stored samples in every case", () => {
    for (const testCase of conformance.cases) {
      expect(Rfc3339InstantSchema.safeParse(testCase.now).success, testCase.name).toBe(true);
      expect(Number.isInteger(testCase.utc_offset_seconds), testCase.name).toBe(true);
      const snapshot = QuotaSnapshotSchema.safeParse({
        provider: "cursor",
        account: { fingerprint: "fp-history", fingerprint_scope: "global" },
        windows: [testCase.window],
        status: "available",
        observed_at: testCase.now,
      });
      expect(snapshot.success, testCase.name).toBe(true);
      for (const sample of testCase.samples) {
        expect(Rfc3339InstantSchema.safeParse(sample.resets_at).success, testCase.name).toBe(true);
        expect(Rfc3339InstantSchema.safeParse(sample.observed_at).success, testCase.name).toBe(
          true,
        );
        expect(sample.used_percent, testCase.name).toBeGreaterThanOrEqual(0);
        expect(sample.used_percent, testCase.name).toBeLessThanOrEqual(100);
      }
    }
  });

  it("states one well-formed fold per case", () => {
    for (const testCase of conformance.cases) {
      const { expected, name } = testCase;
      if (expected === null) {
        continue;
      }
      let previous = -1;
      for (const point of expected.points) {
        expect(point.elapsed_fraction, name).toBeGreaterThanOrEqual(0);
        expect(point.elapsed_fraction, name).toBeLessThanOrEqual(1);
        expect(point.used_percent, name).toBeGreaterThanOrEqual(previous);
        previous = point.used_percent;
      }
      if (expected.projection) {
        expect(expected.projection.elapsed_fraction, name).toBe(1);
        expect(expected.projection.used_percent, name).toBeLessThanOrEqual(999);
      }
      let lastStart = "";
      for (const window of expected.windows_today) {
        expect(Rfc3339InstantSchema.safeParse(window.started_at).success, name).toBe(true);
        expect(Rfc3339InstantSchema.safeParse(window.resets_at).success, name).toBe(true);
        expect(window.started_at > lastStart, name).toBe(true);
        lastStart = window.started_at;
      }
      expect(
        expected.windows_today.filter((window) => window.is_current).length,
        name,
      ).toBeLessThan(2);
    }
  });

  it("covers a fold with no history, a curve with no projection, and several windows today", () => {
    expect(conformance.cases.some((testCase) => testCase.expected === null)).toBe(true);
    expect(
      conformance.cases.some(
        (testCase) => testCase.expected !== null && testCase.expected.projection === null,
      ),
    ).toBe(true);
    expect(
      conformance.cases.some(
        (testCase) => testCase.expected !== null && testCase.expected.windows_today.length >= 3,
      ),
    ).toBe(true);
  });
});
