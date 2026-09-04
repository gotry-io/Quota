import { remainingPercent } from "@gotry-io/quota-model";
import type {
  AccountDeviceRead,
  AccountSummaryRead,
  UsagePeriodRead,
} from "@gotry-io/quota-protocol";
import { deviceActivity } from "./device-activity.ts";
import { relativeAge, usageModelDisplayName } from "./format.ts";

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

function reportingCount(devices: readonly DeviceRow[], now?: Date): number {
  return devices.filter((device) => deviceActivity(device, now).label !== "Not reporting").length;
}

export function accountStatusLine(summary: AccountSummaryRead, now?: Date): string {
  const observed = newestSubscriptionObservedAt(summary);
  const quota = observed
    ? `Latest quota updated ${relativeAge(observed, now)}`
    : "Latest quota not checked";
  const reporting = reportingCount(summary.devices, now);
  const noun = reporting === 1 ? "device" : "devices";
  return `${quota} · ${reporting} ${noun} reporting`;
}

export function usageStatusLine(periodLabel: string, partial: boolean): string {
  return partial ? `${periodLabel} · some hours incomplete` : periodLabel;
}

function activitySeverity(label: string): number {
  if (label === "Not reporting") return 2;
  if (label === "Idle") return 1;
  return 0;
}

function oldestDevice(
  devices: readonly DeviceRow[],
  now?: Date,
): { display_name: string; label: string } | null {
  let worst: { display_name: string; label: string; severity: number; sinceMs: number } | null =
    null;
  for (const device of devices) {
    const activity = deviceActivity(device, now);
    const severity = activitySeverity(activity.label);
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

export function devicesSummaryLine(devices: readonly DeviceRow[], now?: Date): string {
  if (devices.length === 0) return "No devices yet";
  const reporting = reportingCount(devices, now);
  const oldest = oldestDevice(devices, now);
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
