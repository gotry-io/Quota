import conformanceJson from "../../protocol/fixtures/quota-history-sync-conformance.json" with {
  type: "json",
};
import { describe, expect, it } from "vitest";
import {
  bucketQuotaSamples,
  mergeQuotaHistory,
  QUOTA_HISTORY_MAX_SPAN_SECONDS,
  QUOTA_HISTORY_MIN_SPAN_SECONDS,
  QUOTA_HISTORY_SPAN_DURATION_MULTIPLE,
  quotaHistoryExpiresAt,
  quotaHistoryReseedOldest,
  quotaHistoryRowsLost,
  quotaHistorySpanSeconds,
  quotaHistoryUploadPointOutOfRange,
} from "../src/index.ts";
import type {
  QuotaHistoryLocalSample,
  QuotaHistoryMergePoint,
  QuotaHistoryUploadAnswer,
} from "../src/index.ts";
import type { QuotaHistoryPoint } from "@gotry-io/quota-protocol";

type BucketCase = {
  name: string;
  now?: string;
  duration_seconds?: number;
  samples: QuotaHistoryLocalSample[];
  previous: QuotaHistoryPoint[];
  expected: QuotaHistoryPoint[] | { refused: true };
};

type MergeCase = {
  name: string;
  devices: QuotaHistoryMergePoint[][];
  expected: QuotaHistoryMergePoint[];
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
  rows_lost: RowsLostCase[];
  reseed_oldest: ReseedCase[];
};

type RowsLostCase = {
  name: string;
  now: string;
  duration_seconds: number;
  recorded_oldest: string | null;
  watermark: string | null;
  chunk_oldest: string;
  answer: QuotaHistoryUploadAnswer;
  expected: boolean;
};

type ReseedCase = {
  name: string;
  now: string;
  duration_seconds: number;
  recorded_oldest: string | null;
  chunk_oldest: string;
  expected: string;
};

describe("quota history sync conformance", () => {
  it("buckets every case in the shared fixture", () => {
    expect(fixture.bucket.length).toBeGreaterThanOrEqual(6);
    expect(fixture.short_window_bucket_seconds).toBe(900);
    expect(fixture.long_window_bucket_seconds).toBe(3_600);
    expect(fixture.short_window_max_duration_seconds).toBe(86_400);
    expect(fixture.span_min_seconds).toBe(QUOTA_HISTORY_MIN_SPAN_SECONDS);
    expect(fixture.span_max_seconds).toBe(QUOTA_HISTORY_MAX_SPAN_SECONDS);
    expect(fixture.span_duration_multiple).toBe(QUOTA_HISTORY_SPAN_DURATION_MULTIPLE);
    expect(quotaHistorySpanSeconds(18_000)).toBe(48 * 3_600);
    expect(quotaHistorySpanSeconds(604_800)).toBe(28 * 86_400);
    expect(quotaHistorySpanSeconds(2_592_000)).toBe(30 * 86_400);
    expect(quotaHistoryExpiresAt("2026-09-19T10:00:00Z", 18_000)).toBe("2026-09-21T10:00:00Z");
    const now = "2026-09-21T10:00:00Z";
    expect(quotaHistoryUploadPointOutOfRange("2026-09-21T10:15:00Z", 18_000, now)).toBe(false);
    expect(quotaHistoryUploadPointOutOfRange("2026-09-21T10:30:00Z", 18_000, now)).toBe(true);
    expect(quotaHistoryUploadPointOutOfRange("2026-09-19T09:45:00Z", 18_000, now)).toBe(false);
    expect(quotaHistoryUploadPointOutOfRange("2026-09-19T09:30:00Z", 18_000, now)).toBe(true);
    expect(fixture.retention_days).toBe(30);
    for (const testCase of fixture.bucket) {
      expect(
        bucketQuotaSamples(
          testCase.samples,
          testCase.duration_seconds,
          testCase.previous,
          testCase.now ?? fixture.now,
        ),
        testCase.name,
      ).toEqual(Array.isArray(testCase.expected) ? { ok: testCase.expected } : testCase.expected);
    }
  });

  it("merges every case in the shared fixture", () => {
    expect(fixture.merge.length).toBeGreaterThanOrEqual(2);
    for (const testCase of fixture.merge) {
      expect(mergeQuotaHistory(testCase.devices), testCase.name).toEqual(testCase.expected);
    }
  });

  it("judges every rows_lost case and re-seeds every reseed_oldest case", () => {
    expect(fixture.rows_lost.length).toBeGreaterThanOrEqual(15);
    for (const testCase of fixture.rows_lost) {
      expect(
        quotaHistoryRowsLost({
          recordedOldest: testCase.recorded_oldest,
          watermark: testCase.watermark,
          chunkOldest: testCase.chunk_oldest,
          answer: testCase.answer,
          durationSeconds: testCase.duration_seconds,
          now: testCase.now,
        }),
        testCase.name,
      ).toBe(testCase.expected);
    }
    expect(fixture.reseed_oldest.length).toBeGreaterThanOrEqual(4);
    for (const testCase of fixture.reseed_oldest) {
      expect(
        quotaHistoryReseedOldest(
          testCase.recorded_oldest,
          testCase.chunk_oldest,
          testCase.duration_seconds,
          testCase.now,
        ),
        testCase.name,
      ).toBe(testCase.expected);
    }
  });
});
