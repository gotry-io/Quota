import conformanceJson from "../fixtures/quota-history-sync-conformance.json" with { type: "json" };
import { describe, expect, it } from "vitest";
import {
  QUOTA_HISTORY_LONG_WINDOW_BUCKET_SECONDS,
  QUOTA_HISTORY_RETENTION_DAYS,
  QUOTA_HISTORY_SHORT_WINDOW_BUCKET_SECONDS,
  QUOTA_HISTORY_SHORT_WINDOW_MAX_DURATION_SECONDS,
  Rfc3339InstantSchema,
  isAlignedQuotaHistoryBucketStart,
} from "../src/index.ts";

type HistoryPoint = { resets_at: string; bucket_start: string; used_percent: number };

type BucketCase = {
  name: string;
  now?: string;
  duration_seconds?: number;
  samples: { resets_at: string; observed_at: string; used_percent: number }[];
  previous: HistoryPoint[];
  expected: HistoryPoint[] | { refused: true };
};

type MergeCase = {
  name: string;
  devices: { window_id: string; resets_at: string; bucket_start: string; used_percent: number }[][];
  expected: { window_id: string; resets_at: string; bucket_start: string; used_percent: number }[];
};

const fixture = conformanceJson as unknown as {
  now: string;
  short_window_bucket_seconds: number;
  long_window_bucket_seconds: number;
  short_window_max_duration_seconds: number;
  span_min_seconds: number;
  span_max_seconds: number;
  span_duration_multiple: number;
  retention_days: number;
  bucket: BucketCase[];
  merge: MergeCase[];
};

describe("quota history sync fixture", () => {
  it("states the bucket sizes, span, and enough cases that Swift and Rust can answer it", () => {
    expect(fixture.short_window_bucket_seconds).toBe(QUOTA_HISTORY_SHORT_WINDOW_BUCKET_SECONDS);
    expect(fixture.long_window_bucket_seconds).toBe(QUOTA_HISTORY_LONG_WINDOW_BUCKET_SECONDS);
    expect(fixture.short_window_max_duration_seconds).toBe(
      QUOTA_HISTORY_SHORT_WINDOW_MAX_DURATION_SECONDS,
    );
    expect(fixture.span_min_seconds).toBe(48 * 3_600);
    expect(fixture.span_max_seconds).toBe(30 * 86_400);
    expect(fixture.span_duration_multiple).toBe(4);
    expect(Rfc3339InstantSchema.safeParse(fixture.now).success).toBe(true);
    expect(fixture.retention_days).toBe(QUOTA_HISTORY_RETENTION_DAYS);
    expect(fixture.bucket.length).toBeGreaterThanOrEqual(6);
    expect(fixture.merge.length).toBeGreaterThanOrEqual(2);
  });

  it("names placeable instants and aligned expected bucket starts", () => {
    for (const testCase of fixture.bucket) {
      const now = testCase.now ?? fixture.now;
      expect(Rfc3339InstantSchema.safeParse(now).success, testCase.name).toBe(true);
      if (testCase.duration_seconds !== undefined) {
        expect(Number.isInteger(testCase.duration_seconds), testCase.name).toBe(true);
      }
      for (const sample of testCase.samples) {
        expect(Rfc3339InstantSchema.safeParse(sample.observed_at).success, testCase.name).toBe(
          true,
        );
        expect(Rfc3339InstantSchema.safeParse(sample.resets_at).success, testCase.name).toBe(true);
        expect(sample.used_percent, testCase.name).toBeGreaterThanOrEqual(0);
        expect(sample.used_percent, testCase.name).toBeLessThanOrEqual(100);
      }
      const expectedPoints = Array.isArray(testCase.expected) ? testCase.expected : [];
      for (const point of [...testCase.previous, ...expectedPoints]) {
        expect(Rfc3339InstantSchema.safeParse(point.bucket_start).success, testCase.name).toBe(
          true,
        );
        if (testCase.duration_seconds !== undefined) {
          expect(
            isAlignedQuotaHistoryBucketStart(point.bucket_start, testCase.duration_seconds),
            testCase.name,
          ).toBe(true);
        }
      }
    }
    for (const testCase of fixture.merge) {
      for (const point of testCase.devices.flat()) {
        expect(Rfc3339InstantSchema.safeParse(point.bucket_start).success, testCase.name).toBe(
          true,
        );
        expect(point.window_id.length, testCase.name).toBeGreaterThan(0);
      }
    }
  });
});
