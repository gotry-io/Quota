import type { QuotaSnapshot, QuotaWindow } from "@gotry-io/quota-protocol";
import { asRecord, readNumber, readString } from "../../runtime/files.ts";
import { accountIdentity, maskEmail } from "../../runtime/identity.ts";
import { clampPercent, dateToIso, parseFlexibleDate, toIsoOffset } from "../../runtime/time.ts";
import { CLAUDE_SOURCE_API } from "./credentials.ts";

const FIVE_HOUR_SECONDS = 5 * 60 * 60;
const SEVEN_DAY_SECONDS = 7 * 24 * 60 * 60;

export interface ClaudeMappedUsage {
  windows: QuotaWindow[];
  usable: boolean;
}

export function mapClaudeUsageResponse(json: unknown): ClaudeMappedUsage {
  const root = asRecord(json);
  if (!root) {
    return { windows: [], usable: false };
  }

  const windows: QuotaWindow[] = [];
  const fiveHour = mapUsageWindow(root.five_hour, "five_hour", "5 hour", FIVE_HOUR_SECONDS);
  const sevenDay = mapUsageWindow(root.seven_day, "seven_day", "Weekly", SEVEN_DAY_SECONDS);
  if (fiveHour) {
    windows.push(fiveHour);
  }
  if (sevenDay) {
    windows.push(sevenDay);
  }

  const flatExtras: Array<[unknown, string, string]> = [
    [root.seven_day_sonnet, "seven_day_sonnet", "Sonnet weekly"],
    [root.seven_day_opus, "seven_day_opus", "Opus weekly"],
    [root.seven_day_oauth_apps, "seven_day_oauth_apps", "OAuth apps weekly"],
  ];
  for (const [value, id, title] of flatExtras) {
    const window = mapUsageWindow(value, id, title, SEVEN_DAY_SECONDS);
    if (window) {
      windows.push(window);
    }
  }

  const routines = firstPresent(root, [
    "seven_day_routines",
    "seven_day_claude_routines",
    "claude_routines",
    "routines",
    "routine",
    "seven_day_cowork",
    "cowork",
  ]);
  const routinesWindow = mapUsageWindow(
    routines,
    "claude-routines",
    "Daily Routines",
    SEVEN_DAY_SECONDS,
  );
  const scoped = mapScopedWeeklyLimits(root.limits);
  windows.push(...scoped);
  if (routinesWindow) {
    windows.push(routinesWindow);
  }

  const extraUsage = asRecord(root.extra_usage) ?? asRecord(root.extraUsage);
  const extraUtilization = readNumber(extraUsage, "utilization");
  if (extraUtilization !== undefined) {
    windows.push({
      id: "extra_usage",
      title: "Extra usage",
      used_percent: clampPercent(extraUtilization),
    });
  }

  return { windows, usable: windows.length > 0 };
}

export function buildClaudeSnapshot(input: {
  windows: QuotaWindow[];
  plan?: string;
  email?: string;
  organizationId?: string;
  now?: Date;
}): QuotaSnapshot {
  const now = input.now ?? new Date();
  const identity = accountIdentity("claude", "organization_id", input.organizationId);
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
    provider: "claude",
    account,
    windows: input.windows,
    source: CLAUDE_SOURCE_API,
    status: "available",
    observed_at: toIsoOffset(now),
  };
}

export function mapClaudeProfile(json: unknown): {
  email?: string;
  organizationId?: string;
} {
  const root = asRecord(json);
  if (!root) {
    return {};
  }
  const account = asRecord(root.account);
  const organization = asRecord(root.organization);
  const email =
    readString(account, "emailAddress", "email_address", "email") ??
    readString(root, "emailAddress", "email_address", "email");
  const organizationId =
    readString(organization, "uuid") ?? readString(root, "organizationUuid", "organization_uuid");
  return {
    ...(email ? { email } : {}),
    ...(organizationId ? { organizationId } : {}),
  };
}

function mapUsageWindow(
  value: unknown,
  id: string,
  title: string,
  durationSeconds: number,
): QuotaWindow | undefined {
  if (value === null || value === undefined) {
    return undefined;
  }
  const record = asRecord(value);
  if (!record) {
    return undefined;
  }
  const utilization = readNumber(record, "utilization");
  if (utilization === undefined) {
    return undefined;
  }
  const resetsAtRaw = readString(record, "resets_at", "resetsAt");
  const resetsAt = resetsAtRaw ? dateToIso(parseFlexibleDate(resetsAtRaw)) : undefined;
  return {
    id,
    title,
    used_percent: clampPercent(utilization),
    ...(resetsAt ? { resets_at: resetsAt } : {}),
    duration_seconds: durationSeconds,
  };
}

function mapScopedWeeklyLimits(value: unknown): QuotaWindow[] {
  if (!Array.isArray(value)) {
    return [];
  }
  const seen = new Set<string>();
  const windows: QuotaWindow[] = [];
  for (const entry of value) {
    const record = asRecord(entry);
    if (!record) {
      continue;
    }
    const kind = readString(record, "kind");
    const group = readString(record, "group");
    if (kind !== "weekly_scoped" || group !== "weekly") {
      continue;
    }
    // is_active is intentionally not a hard filter; observed enforceable limits may report false.
    const percent = readNumber(record, "percent");
    if (percent === undefined) {
      continue;
    }
    const scope = asRecord(record.scope);
    const model = asRecord(scope?.model);
    const modelName = readString(model, "display_name", "displayName");
    const modelId = readString(model, "id");
    if (!modelName || isAllModelsScope(modelId, modelName)) {
      continue;
    }
    const identity = modelId ?? modelName;
    const id = `claude-weekly-scoped-${slug(identity)}`;
    if (!seen.add(id)) {
      continue;
    }
    const resetsAtRaw = readString(record, "resets_at", "resetsAt");
    const resetsAt = resetsAtRaw ? dateToIso(parseFlexibleDate(resetsAtRaw)) : undefined;
    windows.push({
      id,
      title: `${modelName} only`,
      used_percent: clampPercent(percent),
      ...(resetsAt ? { resets_at: resetsAt } : {}),
      duration_seconds: SEVEN_DAY_SECONDS,
    });
  }
  return windows;
}

function isAllModelsScope(modelId: string | undefined, modelName: string): boolean {
  if (slug(modelName) === "all-models") {
    return true;
  }
  if (!modelId) {
    return false;
  }
  const idSlug = slug(modelId);
  return idSlug === "all-models" || idSlug.endsWith("-all-models");
}

function firstPresent(root: Record<string, unknown>, keys: string[]): unknown {
  for (const key of keys) {
    if (key in root && root[key] !== undefined) {
      return root[key];
    }
  }
  return undefined;
}

function slug(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function claudePlanLabel(
  subscriptionType?: string,
  rateLimitTier?: string,
): string | undefined {
  const plan = subscriptionType?.trim() || rateLimitTier?.trim();
  return plan || undefined;
}
