import { remainingPercent } from "@gotry-io/quota-model";
import type {
  AccountDeviceRead,
  AccountSummaryRead,
  UsagePeriodRead,
} from "@gotry-io/quota-protocol";
import { deviceActivity } from "./device-activity.ts";
import { relativeAge, usageModelDisplayName, WEB_LOCALE } from "./format.ts";

export type MeterTone = "good" | "warn" | "critical";

type DeviceRow = Pick<
  AccountDeviceRead,
  "id" | "display_name" | "last_seen_at" | "last_observed_at"
>;

/** Remaining-quota meter fill, the same bands QuotaBar paints: ≥40 good, 15–39 warn, <15 critical. */
export function meterTone(remaining: number): MeterTone {
  if (remaining >= 40) return "good";
  if (remaining >= 15) return "warn";
  return "critical";
}

export function meterToneForUsedPercent(usedPercent: number): MeterTone {
  return meterTone(remainingPercent(usedPercent));
}

/** Stable hue in 0–359 from a provider id, for letter-mark fallbacks. */
export function providerMarkHue(providerId: string): number {
  let hash = 2166136261;
  for (const char of providerId) {
    hash ^= char.charCodeAt(0);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0) % 360;
}

export function viewerInitial(label: string | undefined): string {
  const trimmed = label?.trim() ?? "";
  const first = trimmed.charAt(0);
  return first ? first.toUpperCase() : "Q";
}

/** Largest-token model in a period tree, or an em dash when the tree is empty. */
export function topUsageModel(period: UsagePeriodRead | null | undefined): string {
  if (!period) return "—";
  let best: { name: string; tokens: number } | null = null;
  for (const agent of period.agents) {
    for (const provider of agent.providers) {
      for (const model of provider.models) {
        const tokens = model.totals.total_tokens;
        if (best === null || tokens > best.tokens) {
          best = { name: model.model, tokens };
        }
      }
    }
  }
  if (best === null || best.tokens <= 0) return "—";
  return usageModelDisplayName(best.name);
}

function newestSubscriptionObservedAt(summary: AccountSummaryRead): string | null {
  let newest: string | null = null;
  let newestMs = Number.NEGATIVE_INFINITY;
  for (const subscription of summary.subscriptions) {
    const value = subscription.snapshot.observed_at;
    const ms = Date.parse(value);
    if (!Number.isFinite(ms) || ms <= newestMs) continue;
    newestMs = ms;
    newest = value;
  }
  return newest;
}

export const SYNC_OFF_COPY = "Sync is off. Your Macs stop uploading until you subscribe.";

/** Paid sync is the write gate: `active` and `grace` may upload; anything else may not. */
export function isPaidSyncStatus(status: string): boolean {
  return status === "active" || status === "grace";
}

export function subscribeActionLabel(status: string): "Subscribe" | "Manage subscription" {
  return isPaidSyncStatus(status) ? "Manage subscription" : "Subscribe";
}

type EntitlementView = {
  status: string;
  expires_at: string | null;
  will_renew: boolean;
  stale: boolean;
  updated_at?: unknown;
};

/** Local calendar day of an RFC 3339 instant, English month and day, no year. */
export function formatEntitlementDay(
  instant: string,
  timeZone: string = Intl.DateTimeFormat().resolvedOptions().timeZone,
): string {
  return new Intl.DateTimeFormat(WEB_LOCALE, {
    month: "short",
    day: "numeric",
    timeZone,
  }).format(new Date(instant));
}

function entitlementCheckedAt(entitlement: EntitlementView): string | null {
  return typeof entitlement.updated_at === "string" &&
    Number.isFinite(Date.parse(entitlement.updated_at))
    ? entitlement.updated_at
    : null;
}

/** Settings Sync status. Stale appends last-checked only when `updated_at` is a readable instant. */
export function entitlementStatusLine(
  entitlement: EntitlementView,
  now: Date = new Date(),
  timeZone?: string,
): string {
  const day =
    entitlement.expires_at !== null && Number.isFinite(Date.parse(entitlement.expires_at))
      ? formatEntitlementDay(entitlement.expires_at, timeZone)
      : null;
  let line: string;
  if (entitlement.status === "active") {
    line = day ? `Active · ${entitlement.will_renew ? "renews" : "ends"} ${day}` : "Active";
  } else if (entitlement.status === "grace") {
    line = "Grace period · update your payment";
  } else {
    line = "Not subscribed";
  }
  if (!entitlement.stale) return line;
  const checkedAt = entitlementCheckedAt(entitlement);
  if (checkedAt === null) return line;
  return `${line} · last checked ${relativeAge(checkedAt, now)}`;
}

function reportingCount(devices: readonly DeviceRow[], now?: Date, subscribed = true): number {
  return devices.filter(
    (device) => deviceActivity(device, now, { subscribed }).tone !== "unavailable",
  ).length;
}

export function accountStatusLine(summary: AccountSummaryRead, now?: Date): string {
  const observed = newestSubscriptionObservedAt(summary);
  const quota = observed
    ? `Latest quota updated ${relativeAge(observed, now)}`
    : "Latest quota not checked";
  const subscribed = isPaidSyncStatus(summary.entitlement.status);
  const reporting = reportingCount(summary.devices, now, subscribed);
  const noun = reporting === 1 ? "device" : "devices";
  return `${quota} · ${reporting} ${noun} reporting`;
}

export function usageStatusLine(periodLabel: string, partial: boolean): string {
  return partial ? `${periodLabel} · some hours incomplete` : periodLabel;
}

function activitySeverity(tone: "available" | "offline" | "unavailable", label: string): number {
  if (tone === "unavailable") return 2;
  if (label === "Idle") return 1;
  return 0;
}

function oldestDevice(
  devices: readonly DeviceRow[],
  now?: Date,
  subscribed = true,
): { display_name: string; label: string } | null {
  let worst: { display_name: string; label: string; severity: number; sinceMs: number } | null =
    null;
  for (const device of devices) {
    const activity = deviceActivity(device, now, { subscribed });
    const severity = activitySeverity(activity.tone, activity.label);
    const sinceMs = activity.since ? Date.parse(activity.since) : Number.NEGATIVE_INFINITY;
    if (
      worst === null ||
      severity > worst.severity ||
      (severity === worst.severity && sinceMs < worst.sinceMs)
    ) {
      worst = { display_name: device.display_name, label: activity.label, severity, sinceMs };
    }
  }
  return worst;
}

export function devicesSummaryLine(
  devices: readonly DeviceRow[],
  now?: Date,
  options: { subscribed?: boolean } = {},
): string {
  if (devices.length === 0) return "No devices yet";
  const subscribed = options.subscribed ?? true;
  const reporting = reportingCount(devices, now, subscribed);
  const oldest = oldestDevice(devices, now, subscribed);
  const count =
    reporting === devices.length
      ? `${devices.length} ${devices.length === 1 ? "device" : "devices"} · all reporting`
      : `${reporting} of ${devices.length} reporting`;
  if (!oldest) return count;
  return `${count} · ${oldest.display_name} · ${oldest.label}`;
}

export function subscriptionCardMeta(deviceName: string, observedAt: string, now?: Date): string {
  return `${deviceName} · ${relativeAge(observedAt, now)}`;
}
