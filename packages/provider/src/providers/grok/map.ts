import type { QuotaSnapshot, QuotaWindow } from "@gotry-io/quota-protocol";
import { asRecord, readNumber } from "../../runtime/files.ts";
import { accountFingerprint, maskDisplayName, maskEmail } from "../../runtime/identity.ts";
import {
  clampPercent,
  dateToIso,
  durationSecondsFromDates,
  parseFlexibleDate,
  toIsoOffset,
} from "../../runtime/time.ts";
import { GROK_SOURCE_API, type GrokCredentials, grokDisplayName } from "./credentials.ts";

export function mapGrokBillingResponse(json: unknown): {
  window?: QuotaWindow;
  usable: boolean;
} {
  const root = asRecord(json);
  if (!root) {
    return { usable: false };
  }

  const config = asRecord(root.config);
  if (!config) {
    return { usable: false };
  }
  const creditUsagePercent = readNumber(config, "creditUsagePercent");

  let usedPercent: number | undefined;
  if (creditUsagePercent !== undefined) {
    usedPercent = clampPercent(creditUsagePercent);
  } else {
    const monthlyLimit = centValue(config.monthlyLimit);
    const totalUsed = centValue(config.used);
    if (monthlyLimit !== undefined && monthlyLimit > 0 && totalUsed !== undefined) {
      usedPercent = clampPercent((totalUsed / monthlyLimit) * 100);
    }
  }

  if (usedPercent === undefined) {
    return { usable: false };
  }

  const currentPeriod = asRecord(config.currentPeriod);
  const cycle = currentPeriod ?? config;
  const start = parseFlexibleDate(cycle.start ?? cycle.billingPeriodStart);
  const end = parseFlexibleDate(cycle.end ?? cycle.billingPeriodEnd);
  const duration = durationSecondsFromDates(start, end);
  const resetsAt = dateToIso(end);
  const title = periodTitle(currentPeriod);

  const window: QuotaWindow = {
    id: "billing_cycle",
    title,
    used_percent: usedPercent,
    ...(resetsAt ? { resets_at: resetsAt } : {}),
    ...(duration !== undefined ? { duration_seconds: duration } : {}),
  };
  return { window, usable: true };
}

export function buildGrokSnapshot(input: {
  window: QuotaWindow;
  credentials?: GrokCredentials;
  now?: Date;
}): QuotaSnapshot {
  const now = input.now ?? new Date();
  const credentials = input.credentials;
  const fingerprint = accountFingerprint(
    "grok",
    credentials?.userId ?? credentials?.email ?? credentials?.teamId,
    credentials?.scope,
  );
  const label =
    maskEmail(credentials?.email) ??
    maskDisplayName(credentials ? grokDisplayName(credentials) : undefined);
  const account: QuotaSnapshot["account"] = { fingerprint };
  if (label) {
    account.label = label;
  }

  return {
    provider: "grok",
    account,
    windows: [input.window],
    source: GROK_SOURCE_API,
    status: "available",
    observed_at: toIsoOffset(now),
  };
}

function periodTitle(period: Record<string, unknown> | undefined): string {
  const type = period?.type ?? period?.periodType ?? period?.period_type;
  if (typeof type !== "string") {
    return "Billing cycle";
  }
  const normalized = type.toLowerCase();
  if (normalized.includes("weekly")) {
    return "Weekly";
  }
  if (normalized.includes("monthly")) {
    return "Monthly";
  }
  return "Billing cycle";
}

function centValue(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  const record = asRecord(value);
  return readNumber(record, "val");
}
