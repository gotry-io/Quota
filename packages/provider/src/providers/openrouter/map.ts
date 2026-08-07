import type { QuotaSnapshot, QuotaWindow } from "@gotry-io/quota-protocol";
import type { ApiKeyCredentials } from "../../api-key/resolve.ts";
import { asRecord, readNumber } from "../../runtime/files.ts";
import { accountIdentity, sha256Hex } from "../../runtime/identity.ts";
import { clampPercent, toIsoOffset } from "../../runtime/time.ts";
export const OPENROUTER_SOURCE_API = "openrouter_api";

export interface OpenRouterCreditsData {
  totalCredits: number;
  totalUsage: number;
  balance: number;
}

export interface OpenRouterKeyData {
  limit?: number;
  limitRemaining?: number;
  limitReset?: string;
  usage?: number;
  usageDaily?: number;
  usageWeekly?: number;
  usageMonthly?: number;
}

export function mapOpenRouterCreditsResponse(json: unknown): OpenRouterCreditsData | undefined {
  const root = asRecord(json);
  const data = asRecord(root?.data);
  if (!data) {
    return undefined;
  }
  const totalCredits = readNumber(data, "total_credits");
  const totalUsage = readNumber(data, "total_usage");
  if (totalCredits === undefined || totalUsage === undefined) {
    return undefined;
  }
  if (!Number.isFinite(totalCredits) || !Number.isFinite(totalUsage) || totalCredits < 0) {
    return undefined;
  }
  return {
    totalCredits,
    totalUsage,
    balance: Math.max(0, totalCredits - totalUsage),
  };
}

export function mapOpenRouterKeyResponse(json: unknown): OpenRouterKeyData | undefined {
  const root = asRecord(json);
  const data = asRecord(root?.data);
  if (!data) {
    return undefined;
  }

  const limitReset =
    typeof data.limit_reset === "string" && data.limit_reset.trim()
      ? data.limit_reset.trim().toLowerCase()
      : undefined;

  const limit = readNumber(data, "limit");
  const limitRemaining = readNumber(data, "limit_remaining");
  const usage = readNumber(data, "usage");
  const usageDaily = readNumber(data, "usage_daily");
  const usageWeekly = readNumber(data, "usage_weekly");
  const usageMonthly = readNumber(data, "usage_monthly");

  return {
    ...(limit !== undefined ? { limit } : {}),
    ...(limitRemaining !== undefined ? { limitRemaining } : {}),
    ...(limitReset ? { limitReset } : {}),
    ...(usage !== undefined ? { usage } : {}),
    ...(usageDaily !== undefined ? { usageDaily } : {}),
    ...(usageWeekly !== undefined ? { usageWeekly } : {}),
    ...(usageMonthly !== undefined ? { usageMonthly } : {}),
  };
}

/** CodexBar-aligned: key-limit window first when configured, then credits balance. */
export function mapOpenRouterWindows(
  credits: OpenRouterCreditsData | undefined,
  key: OpenRouterKeyData | undefined,
): QuotaWindow[] {
  const windows: QuotaWindow[] = [];

  const keyWindow = keyLimitWindow(key);
  if (keyWindow) {
    windows.push(keyWindow);
  }

  // totalCredits === 0 is a valid empty prepaid balance; only emit a credits meter when > 0.
  if (credits && credits.totalCredits > 0) {
    windows.push({
      id: "credits",
      title: "Credits",
      used_percent: clampPercent((credits.totalUsage / credits.totalCredits) * 100),
      remaining_value: credits.balance,
      limit_value: credits.totalCredits,
      value_unit: "usd",
    });
  }

  return windows;
}

export function buildOpenRouterSnapshot(input: {
  windows: QuotaWindow[];
  credentials: ApiKeyCredentials;
  now?: Date;
}): QuotaSnapshot {
  const now = input.now ?? new Date();
  const keyFingerprint = sha256Hex(input.credentials.apiKey);
  const identity = accountIdentity("openrouter", "api_key", keyFingerprint);

  return {
    provider: "openrouter",
    account: {
      fingerprint: identity.fingerprint,
      fingerprint_scope: identity.scope,
      label: input.credentials.label,
      plan: "OpenRouter",
    },
    windows: input.windows,
    source: OPENROUTER_SOURCE_API,
    status: "available",
    observed_at: toIsoOffset(now),
  };
}

function keyLimitWindow(key: OpenRouterKeyData | undefined): QuotaWindow | undefined {
  if (!key) {
    return undefined;
  }
  const limit = key.limit;
  if (limit === undefined || !(limit > 0)) {
    return undefined;
  }

  const used = keyUsedAmount(key, limit);
  if (used === undefined || !Number.isFinite(used) || used < 0) {
    return undefined;
  }

  const remaining = Math.max(0, limit - used);
  const meta = keyLimitMeta(key.limitReset);
  return {
    id: meta.id,
    title: meta.title,
    used_percent: clampPercent((used / limit) * 100),
    remaining_value: remaining,
    limit_value: limit,
    value_unit: "usd",
  };
}

function keyUsedAmount(key: OpenRouterKeyData, limit: number): number | undefined {
  if (key.limitRemaining !== undefined && Number.isFinite(key.limitRemaining)) {
    const remaining = Math.min(limit, Math.max(0, key.limitRemaining));
    return limit - remaining;
  }
  switch (key.limitReset) {
    case "daily":
      return key.usageDaily;
    case "weekly":
      return key.usageWeekly;
    case "monthly":
      return key.usageMonthly;
    default:
      return key.usage;
  }
}

function keyLimitMeta(reset: string | undefined): { id: string; title: string } {
  switch (reset) {
    case "daily":
      return { id: "key_daily", title: "API key daily" };
    case "weekly":
      return { id: "key_weekly", title: "API key weekly" };
    case "monthly":
      return { id: "key_monthly", title: "API key monthly" };
    default:
      return { id: "key_budget", title: "API key budget" };
  }
}
