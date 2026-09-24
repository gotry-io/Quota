import {
  canonicalRfc3339Utc,
  quotaHistoryBucketSeconds,
  quotaHistoryBucketStartUtc,
  type QuotaHistoryPoint,
} from "@gotry-io/quota-protocol";

/** One local remaining-quota reading, before it is downsampled for upload. */
export type QuotaHistoryLocalSample = {
  observed_at: string;
  used_percent: number;
  resets_at: string;
};

export type QuotaHistorySyncedPoint = QuotaHistoryPoint;

/** A merged Account point: the local 12-hex selector is never on the wire. */
export type QuotaHistoryMergePoint = QuotaHistoryPoint & {
  window_id: string;
};

export type BucketQuotaSamplesResult = { ok: QuotaHistorySyncedPoint[] } | { refused: true };

/** Cap: a monthly window never keeps more than thirty days. */
export const QUOTA_HISTORY_MAX_SPAN_SECONDS = 30 * 86_400;
/** Floor: a chart's left edge is never the retention edge (48 h, not 24 h). */
export const QUOTA_HISTORY_MIN_SPAN_SECONDS = 48 * 3_600;
/** How many window lengths the span covers before the min/max clamp. */
export const QUOTA_HISTORY_SPAN_DURATION_MULTIPLE = 4;

/**
 * How long one window's history is kept and uploaded: `min(30 d, max(48 h, 4 × duration))`.
 *
 * Five-hour → 48 h; weekly → 28 d; monthly → 30 d.
 */
export function quotaHistorySpanSeconds(durationSeconds: number): number {
  return Math.min(
    QUOTA_HISTORY_MAX_SPAN_SECONDS,
    Math.max(
      QUOTA_HISTORY_MIN_SPAN_SECONDS,
      QUOTA_HISTORY_SPAN_DURATION_MULTIPLE * durationSeconds,
    ),
  );
}

function instantMs(now: string | number | Date): number {
  return now instanceof Date ? now.getTime() : typeof now === "number" ? now : Date.parse(now);
}

/** The earliest `bucket_start` that is still inside the window's span, optionally plus slack buckets. */
export function quotaHistorySpanCutoffMs(
  durationSeconds: number,
  now: string | number | Date,
  slackBuckets = 0,
): number {
  const slack = slackBuckets * quotaHistoryBucketSeconds(durationSeconds) * 1_000;
  return instantMs(now) - quotaHistorySpanSeconds(durationSeconds) * 1_000 - slack;
}

/**
 * Canonical RFC 3339 UTC expiry of one bucket: `bucket_start + span(duration_seconds)`.
 * Relay stores this on the row and the sweep deletes where `expires_at < now`.
 */
export function quotaHistoryExpiresAt(bucketStart: string, durationSeconds: number): string {
  return canonicalRfc3339Utc(
    Date.parse(bucketStart) + quotaHistorySpanSeconds(durationSeconds) * 1_000,
  );
}

/**
 * How long before its expiry a bucket stops counting as one Relay must still hold. Relay never
 * sweeps a row before its `expires_at`, but a device clock behind Relay's can make a row go
 * earlier than this device expects. A duration another device shortened is the answer's
 * `duration_seconds`, not this slack.
 */
export const QUOTA_HISTORY_OLDEST_SLACK_SECONDS = 3_600;

/** Relay must still hold this bucket: `bucket + span > now + 1 h`. */
export function quotaHistoryOldestIsLive(
  bucketStart: string,
  durationSeconds: number,
  now: string | number | Date,
): boolean {
  return (
    Date.parse(bucketStart) + quotaHistorySpanSeconds(durationSeconds) * 1_000 >
    instantMs(now) + QUOTA_HISTORY_OLDEST_SLACK_SECONDS * 1_000
  );
}

/** What an upload answer says about one series the upload sent. */
export type QuotaHistoryUploadAnswer =
  | "absent"
  | { oldest_bucket_start?: string; duration_seconds?: number };

/**
 * Relay lost rows of a series this device uploaded (ADR 0062, amendment 2026-09-23).
 *
 * The evidence is the oldest bucket uploaded in this on-period while it is live, otherwise the
 * watermark from before this chunk while it is live and every point of the chunk is later than
 * it. A series the answer leaves out is always a loss: the answer names every series sent. An
 * answer without `oldest_bucket_start` (an older Relay) judges nothing. Liveness uses the
 * shorter of this device's duration and the answer's `duration_seconds` — the one the window's
 * rows expired by, which another device may have shortened (ADR 0062, amendment 2026-09-24).
 */
export function quotaHistoryRowsLost(input: {
  recordedOldest: string | null;
  watermark: string | null;
  chunkOldest: string;
  answer: QuotaHistoryUploadAnswer;
  durationSeconds: number;
  now: string | number | Date;
}): boolean {
  if (input.answer === "absent") return true;
  const answered = input.answer.oldest_bucket_start;
  if (answered === undefined) return false;
  const durationSeconds = Math.min(
    input.durationSeconds,
    input.answer.duration_seconds ?? input.durationSeconds,
  );
  let evidence: string | null = null;
  if (
    input.recordedOldest !== null &&
    quotaHistoryOldestIsLive(input.recordedOldest, durationSeconds, input.now)
  ) {
    evidence = input.recordedOldest;
  } else if (
    input.watermark !== null &&
    quotaHistoryOldestIsLive(input.watermark, durationSeconds, input.now) &&
    Date.parse(input.chunkOldest) > Date.parse(input.watermark)
  ) {
    evidence = input.watermark;
  }
  return evidence !== null && Date.parse(answered) > Date.parse(evidence);
}

/** The recorded oldest after an accepted chunk: the older of a live record and the chunk. */
export function quotaHistoryReseedOldest(
  recordedOldest: string | null,
  chunkOldest: string,
  durationSeconds: number,
  now: string | number | Date,
): string {
  if (
    recordedOldest !== null &&
    quotaHistoryOldestIsLive(recordedOldest, durationSeconds, now) &&
    Date.parse(recordedOldest) <= Date.parse(chunkOldest)
  ) {
    return recordedOldest;
  }
  return chunkOldest;
}

/**
 * Upload refuses a point older than the span plus one bucket of slack, or whose `bucket_start`
 * is more than one bucket ahead of now. One bucket ahead is accepted; two are not.
 */
export function quotaHistoryUploadPointOutOfRange(
  bucketStart: string,
  durationSeconds: number,
  now: string | number | Date,
): boolean {
  const start = Date.parse(bucketStart);
  if (!Number.isFinite(start)) return true;
  if (start < quotaHistorySpanCutoffMs(durationSeconds, now, 1)) return true;
  return start > instantMs(now) + quotaHistoryBucketSeconds(durationSeconds) * 1_000;
}

export function quotaHistoryUploadHasOutOfRangePoint(
  upload: { series: { duration_seconds: number; points: { bucket_start: string }[] }[] },
  now: string | number | Date,
): boolean {
  for (const series of upload.series) {
    for (const point of series.points) {
      if (quotaHistoryUploadPointOutOfRange(point.bucket_start, series.duration_seconds, now)) {
        return true;
      }
    }
  }
  return false;
}

/**
 * Downsample local samples of one window into the points a device uploads.
 *
 * Size is 900 s when `durationSeconds ≤ 86 400`, otherwise 3 600 s. The value of a bucket is
 * the maximum `used_percent` in it for that `resets_at`. A bucket whose value equals the
 * previous uploaded bucket of the same `resets_at` is not sent. Points older than the window's
 * span are dropped. A series with no `duration_seconds` is refused: a producer must know its
 * window.
 */
export function bucketQuotaSamples(
  samples: readonly QuotaHistoryLocalSample[],
  durationSeconds: number | undefined,
  previous: readonly QuotaHistorySyncedPoint[] = [],
  now: string,
): BucketQuotaSamplesResult {
  if (durationSeconds === undefined || !Number.isFinite(durationSeconds) || durationSeconds < 0) {
    return { refused: true };
  }
  const cutoff = quotaHistorySpanCutoffMs(durationSeconds, now);
  const lastByReset = new Map<string, { bucket_start: string; used_percent: number }>();
  for (const point of previous) {
    const current = lastByReset.get(point.resets_at);
    if (!current || point.bucket_start >= current.bucket_start) {
      lastByReset.set(point.resets_at, {
        bucket_start: point.bucket_start,
        used_percent: point.used_percent,
      });
    }
  }
  const buckets = new Map<string, QuotaHistorySyncedPoint>();
  for (const sample of samples) {
    const bucketStart = quotaHistoryBucketStartUtc(sample.observed_at, durationSeconds);
    if (Date.parse(bucketStart) < cutoff) continue;
    const key = `${sample.resets_at}\0${bucketStart}`;
    const existing = buckets.get(key);
    if (!existing || sample.used_percent > existing.used_percent) {
      buckets.set(key, {
        resets_at: sample.resets_at,
        bucket_start: bucketStart,
        used_percent: sample.used_percent,
      });
    }
  }
  const ordered = [...buckets.values()].sort(compareSyncedPoints);
  const uploaded: QuotaHistorySyncedPoint[] = [];
  for (const point of ordered) {
    const last = lastByReset.get(point.resets_at);
    if (last !== undefined && last.used_percent === point.used_percent) continue;
    uploaded.push(point);
    lastByReset.set(point.resets_at, {
      bucket_start: point.bucket_start,
      used_percent: point.used_percent,
    });
  }
  return { ok: uploaded };
}

/**
 * Union several devices' uploaded points: one point per `(window_id, resets_at, bucket_start)`,
 * taking the maximum `used_percent`, oldest first.
 */
export function mergeQuotaHistory(
  devices: readonly (readonly QuotaHistoryMergePoint[])[],
): QuotaHistoryMergePoint[] {
  const merged = new Map<string, QuotaHistoryMergePoint>();
  for (const points of devices) {
    for (const point of points) {
      const key = `${point.window_id}\0${point.resets_at}\0${point.bucket_start}`;
      const existing = merged.get(key);
      if (!existing || point.used_percent > existing.used_percent) {
        merged.set(key, {
          window_id: point.window_id,
          resets_at: point.resets_at,
          bucket_start: point.bucket_start,
          used_percent: point.used_percent,
        });
      }
    }
  }
  return [...merged.values()].sort(compareMergePoints);
}

function compareSyncedPoints(
  left: QuotaHistorySyncedPoint,
  right: QuotaHistorySyncedPoint,
): number {
  return (
    compareText(left.resets_at, right.resets_at) ||
    compareText(left.bucket_start, right.bucket_start)
  );
}

function compareMergePoints(left: QuotaHistoryMergePoint, right: QuotaHistoryMergePoint): number {
  return (
    compareText(left.window_id, right.window_id) ||
    compareText(left.resets_at, right.resets_at) ||
    compareText(left.bucket_start, right.bucket_start)
  );
}

function compareText(left: string, right: string): number {
  if (left === right) return 0;
  return left < right ? -1 : 1;
}
