import type { QuotaSnapshot, QuotaWindow } from "@gotry-io/quota-protocol";
import { asRecord, readNumber, readString } from "../../runtime/files.ts";
import { accountIdentity, maskEmail } from "../../runtime/identity.ts";
import { clampPercent, toIsoOffset, unixSecondsToIso } from "../../runtime/time.ts";

export const CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";
export const CODEX_SOURCE_API = "chatgpt_usage_api";
export const CODEX_SOURCE_RPC = "codex_app_server";

export interface CodexMappedUsage {
  plan?: string;
  email?: string;
  accountId?: string;
  windows: QuotaWindow[];
  usable: boolean;
  malformedSuccess: boolean;
}

export function mapCodexUsageResponse(json: unknown, now = new Date()): CodexMappedUsage {
  const root = asRecord(json);
  if (!root) {
    return { windows: [], usable: false, malformedSuccess: true };
  }

  const plan = readString(root, "plan_type", "planType");
  const email = readString(root, "email");
  const accountId = readString(root, "account_id", "accountId");
  const rateLimit = asRecord(root.rate_limit) ?? asRecord(root.rateLimit);
  const primary = mapWindow(
    asRecord(rateLimit?.primary_window) ?? asRecord(rateLimit?.primaryWindow),
    "five_hour",
    "5 hour",
  );
  const secondary = mapWindow(
    asRecord(rateLimit?.secondary_window) ?? asRecord(rateLimit?.secondaryWindow),
    "weekly",
    "Weekly",
  );

  const normalized = normalizePrimarySecondary(primary, secondary);
  const extras = mapAdditionalRateLimits(
    root.additional_rate_limits ?? root.additionalRateLimits,
    now,
  );
  const windows = [normalized.primary, normalized.secondary, ...extras].filter(
    (window): window is QuotaWindow => window !== undefined,
  );

  const primaryPresent = hasNonNullField(rateLimit, "primary_window", "primaryWindow");
  const secondaryPresent = hasNonNullField(rateLimit, "secondary_window", "secondaryWindow");
  const malformedPrimary = primaryPresent && primary === undefined;
  const malformedSecondary = secondaryPresent && secondary === undefined;
  // Null sibling windows are normal. Only treat the payload as a fatal malformed
  // success when nothing usable could be recovered from a present window object.
  const malformedSuccess = windows.length === 0 && (malformedPrimary || malformedSecondary);

  return {
    ...(plan ? { plan } : {}),
    ...(email ? { email } : {}),
    ...(accountId ? { accountId } : {}),
    windows,
    usable: windows.length > 0,
    malformedSuccess,
  };
}

export function mapCodexRpcRateLimits(json: unknown): CodexMappedUsage {
  const root = asRecord(json);
  if (!root) {
    return { windows: [], usable: false, malformedSuccess: true };
  }
  const rateLimits = asRecord(root.rateLimits) ?? asRecord(root.rate_limits) ?? root;
  const plan = readString(asRecord(rateLimits), "planType", "plan_type");
  const primary = mapRpcWindow(asRecord(asRecord(rateLimits)?.primary), "five_hour", "5 hour");
  const secondary = mapRpcWindow(asRecord(asRecord(rateLimits)?.secondary), "weekly", "Weekly");
  const normalized = normalizePrimarySecondary(primary, secondary);
  const windows = [normalized.primary, normalized.secondary].filter(
    (window): window is QuotaWindow => window !== undefined,
  );
  return {
    ...(plan ? { plan } : {}),
    windows,
    usable: windows.length > 0,
    malformedSuccess: false,
  };
}

export function buildCodexSnapshot(input: {
  source: string;
  windows: QuotaWindow[];
  plan?: string;
  email?: string;
  accountId?: string;
  now?: Date;
}): QuotaSnapshot {
  const now = input.now ?? new Date();
  const identity = accountIdentity("codex", "account_id", input.accountId);
  const label = maskEmail(input.email);
  const account: QuotaSnapshot["account"] = {
    fingerprint: identity.fingerprint,
    fingerprint_scope: identity.scope,
  };
  if (label) {
    account.label = label;
  }
  if (input.plan) {
    account.plan = input.plan;
  }
  return {
    provider: "codex",
    account,
    windows: input.windows,
    source: input.source,
    status: "available",
    observed_at: toIsoOffset(now),
  };
}

function mapWindow(
  record: Record<string, unknown> | undefined,
  id: string,
  title: string,
): QuotaWindow | undefined {
  if (!record) {
    return undefined;
  }
  const used = readNumber(record, "used_percent", "usedPercent");
  if (used === undefined) {
    return undefined;
  }
  const resetAt = readNumber(record, "reset_at", "resetAt");
  const duration = readNumber(record, "limit_window_seconds", "limitWindowSeconds");
  return {
    id,
    title,
    used_percent: clampPercent(used),
    ...(unixSecondsToIso(resetAt) ? { resets_at: unixSecondsToIso(resetAt) } : {}),
    ...(duration !== undefined && duration >= 0 ? { duration_seconds: Math.floor(duration) } : {}),
  };
}

function mapRpcWindow(
  record: Record<string, unknown> | undefined,
  id: string,
  title: string,
): QuotaWindow | undefined {
  if (!record) {
    return undefined;
  }
  const used = readNumber(record, "usedPercent", "used_percent");
  if (used === undefined) {
    return undefined;
  }
  const resetAt = readNumber(record, "resetsAt", "resets_at");
  const minutes = readNumber(record, "windowDurationMins", "window_duration_mins");
  return {
    id,
    title,
    used_percent: clampPercent(used),
    ...(unixSecondsToIso(resetAt) ? { resets_at: unixSecondsToIso(resetAt) } : {}),
    ...(minutes !== undefined && minutes >= 0
      ? { duration_seconds: Math.floor(minutes * 60) }
      : {}),
  };
}

function normalizePrimarySecondary(
  primary: QuotaWindow | undefined,
  secondary: QuotaWindow | undefined,
): { primary?: QuotaWindow; secondary?: QuotaWindow } {
  const role = (window: QuotaWindow | undefined): "session" | "weekly" | "unknown" => {
    if (!window?.duration_seconds) {
      return "unknown";
    }
    if (window.duration_seconds === 5 * 60 * 60) {
      return "session";
    }
    if (window.duration_seconds === 7 * 24 * 60 * 60) {
      return "weekly";
    }
    return "unknown";
  };

  if (primary && secondary) {
    const primaryRole = role(primary);
    const secondaryRole = role(secondary);
    if (
      (primaryRole === "weekly" && secondaryRole === "session") ||
      (primaryRole === "weekly" && secondaryRole === "unknown")
    ) {
      return {
        primary: { ...secondary, id: "five_hour", title: "5 hour" },
        secondary: { ...primary, id: "weekly", title: "Weekly" },
      };
    }
    return {
      primary: { ...primary, id: "five_hour", title: "5 hour" },
      secondary: { ...secondary, id: "weekly", title: "Weekly" },
    };
  }
  if (primary && !secondary) {
    if (role(primary) === "weekly") {
      return { secondary: { ...primary, id: "weekly", title: "Weekly" } };
    }
    return { primary: { ...primary, id: "five_hour", title: "5 hour" } };
  }
  if (!primary && secondary) {
    if (role(secondary) === "session" || role(secondary) === "unknown") {
      return { primary: { ...secondary, id: "five_hour", title: "5 hour" } };
    }
    return { secondary: { ...secondary, id: "weekly", title: "Weekly" } };
  }
  return {};
}

function mapAdditionalRateLimits(value: unknown, _now: Date): QuotaWindow[] {
  if (!Array.isArray(value)) {
    return [];
  }
  const usedIds = new Set<string>();
  const windows: QuotaWindow[] = [];

  for (const entry of value) {
    const record = asRecord(entry);
    if (!record) {
      continue;
    }
    const limitName = readString(record, "limit_name", "limitName");
    const meteredFeature = readString(record, "metered_feature", "meteredFeature");
    const rateLimit = asRecord(record.rate_limit) ?? asRecord(record.rateLimit);
    const primary = asRecord(rateLimit?.primary_window) ?? asRecord(rateLimit?.primaryWindow);
    const secondary = asRecord(rateLimit?.secondary_window) ?? asRecord(rateLimit?.secondaryWindow);

    const isSpark = [limitName, meteredFeature]
      .filter(Boolean)
      .some((item) => item!.toLowerCase().includes("spark"));

    if (isSpark) {
      const candidates: Array<{
        record: Record<string, unknown> | undefined;
        fallback: "five" | "weekly";
      }> = [
        { record: primary, fallback: "five" },
        { record: secondary, fallback: "weekly" },
      ];
      for (const candidate of candidates) {
        const kind = sparkWindowKind(candidate.record, candidate.fallback);
        const mapped = mapWindow(
          candidate.record,
          kind === "five" ? "codex-spark" : "codex-spark-weekly",
          kind === "five" ? "Codex Spark 5-hour" : "Codex Spark Weekly",
        );
        if (mapped && !usedIds.has(mapped.id)) {
          usedIds.add(mapped.id);
          windows.push(mapped);
        }
      }
      continue;
    }

    const snapshot = primary ?? secondary;
    const idSource = meteredFeature ?? limitName;
    if (!snapshot || !idSource) {
      continue;
    }
    const id = `codex-${slug(idSource)}`;
    if (usedIds.has(id)) {
      continue;
    }
    const mapped = mapWindow(snapshot, id, limitName ?? meteredFeature ?? "Codex extra limit");
    if (mapped) {
      usedIds.add(id);
      windows.push(mapped);
    }
  }

  return windows;
}

function slug(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function hasNonNullField(record: Record<string, unknown> | undefined, ...keys: string[]): boolean {
  if (!record) {
    return false;
  }
  for (const key of keys) {
    if (key in record && record[key] !== undefined && record[key] !== null) {
      return true;
    }
  }
  return false;
}

function sparkWindowKind(
  record: Record<string, unknown> | undefined,
  fallback: "five" | "weekly",
): "five" | "weekly" {
  const seconds = readNumber(record, "limit_window_seconds", "limitWindowSeconds");
  if (seconds !== undefined && seconds > 0) {
    const minutes = seconds / 60;
    if (minutes <= 6 * 60) {
      return "five";
    }
    if (minutes >= 6 * 24 * 60) {
      return "weekly";
    }
  }
  return fallback;
}
