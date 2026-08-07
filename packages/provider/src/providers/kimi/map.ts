import type { QuotaWindow } from "@gotry-io/quota-protocol";
import { asRecord, readString } from "../../runtime/files.ts";
import { clampPercent } from "../../runtime/time.ts";

export interface KimiUsageData {
  weekly?: { limit: number; used: number; remaining: number; resetsAt?: string };
  rateLimit?: { limit: number; used: number; remaining: number; resetsAt?: string };
}

/** Parse Kimi Code `GET /coding/v1/usages` (CodexBar-aligned). */
export function mapKimiUsagesResponse(json: unknown): KimiUsageData | undefined {
  const root = asRecord(json);
  if (!root) {
    return undefined;
  }

  const usage = parseUsageDetail(asRecord(root.usage) ?? root);
  const rateLimit = parseRateLimit(root.limits);

  if (!usage && !rateLimit) {
    return undefined;
  }
  return {
    ...(usage ? { weekly: usage } : {}),
    ...(rateLimit ? { rateLimit } : {}),
  };
}

export function mapKimiWindows(data: KimiUsageData): QuotaWindow[] {
  const windows: QuotaWindow[] = [];
  if (data.weekly) {
    windows.push(countWindow("weekly", "Weekly", data.weekly));
  }
  if (data.rateLimit) {
    windows.push(countWindow("five_hour", "5 hour", data.rateLimit));
  }
  return windows;
}

function countWindow(
  id: string,
  title: string,
  detail: { limit: number; used: number; remaining: number; resetsAt?: string },
): QuotaWindow {
  const limit = detail.limit > 0 ? detail.limit : detail.used + detail.remaining;
  const used = Math.max(0, detail.used);
  const remaining = Math.max(0, detail.remaining);
  const denom = limit > 0 ? limit : used + remaining;
  const usedPercent = denom > 0 ? clampPercent((used / denom) * 100) : remaining > 0 ? 0 : 100;
  const window: QuotaWindow = {
    id,
    title,
    used_percent: usedPercent,
    remaining_value: remaining,
    value_unit: "count",
  };
  if (denom > 0) {
    window.limit_value = denom;
  }
  if (detail.resetsAt) {
    window.resets_at = detail.resetsAt;
  }
  return window;
}

function parseUsageDetail(
  record: Record<string, unknown> | undefined,
): { limit: number; used: number; remaining: number; resetsAt?: string } | undefined {
  if (!record) {
    return undefined;
  }
  const limit = readAmount(record, "limit");
  const used = readAmount(record, "used");
  const remaining = readAmount(record, "remaining");
  if (limit === undefined && used === undefined && remaining === undefined) {
    return undefined;
  }
  const resolvedLimit =
    limit ?? (used !== undefined && remaining !== undefined ? used + remaining : 0);
  const resolvedUsed =
    used ?? (resolvedLimit > 0 && remaining !== undefined ? resolvedLimit - remaining : 0);
  const resolvedRemaining =
    remaining ?? (resolvedLimit > 0 ? Math.max(0, resolvedLimit - resolvedUsed) : 0);
  const resetsAt = readString(record, "resetTime", "reset_time", "resets_at");
  return {
    limit: resolvedLimit,
    used: resolvedUsed,
    remaining: resolvedRemaining,
    ...(resetsAt && isIsoDate(resetsAt) ? { resetsAt } : {}),
  };
}

function parseRateLimit(
  limits: unknown,
): { limit: number; used: number; remaining: number; resetsAt?: string } | undefined {
  if (!Array.isArray(limits)) {
    return undefined;
  }
  for (const entry of limits) {
    const record = asRecord(entry);
    if (!record) {
      continue;
    }
    const window = asRecord(record.window);
    const duration = window ? readAmount(window, "duration") : undefined;
    const timeUnit = window ? readString(window, "timeUnit", "time_unit") : undefined;
    // 300 minutes ≈ 5 hour window used by Kimi Code.
    const isFiveHour =
      duration === 300 &&
      (timeUnit === "TIME_UNIT_MINUTE" ||
        timeUnit === "minute" ||
        timeUnit === "MINUTE" ||
        timeUnit === undefined);
    if (!isFiveHour && limits.length > 1) {
      continue;
    }
    const detail = parseUsageDetail(asRecord(record.detail) ?? record);
    if (detail) {
      return detail;
    }
  }
  return undefined;
}

function readAmount(record: Record<string, unknown>, key: string): number | undefined {
  const value = record[key];
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return undefined;
}

function isIsoDate(value: string): boolean {
  return !Number.isNaN(Date.parse(value));
}
