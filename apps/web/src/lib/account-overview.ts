import { remainingPercent } from "@gotry-io/quota-model";
import type {
  AccountDeviceRead,
  AccountSummaryRead,
  UsagePeriodRead,
} from "@gotry-io/quota-protocol";
import { deviceActivity } from "./device-activity.ts";
import { relativeAge, updatedCopy, usageModelDisplayName } from "./format.ts";

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

export function githubLoginFromLabel(label: string | undefined): string | null {
  if (!label) return null;
  const trimmed = label.trim();
  if (trimmed === "Account" || trimmed === "GitHub account") return null;
  if (!/^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?$/.test(trimmed)) return null;
  return trimmed;
}

export function githubAvatarUrl(login: string): string {
  return `https://github.com/${encodeURIComponent(login)}.png?size=64`;
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

function newestInstant(summary: AccountSummaryRead): string | null {
  let newest: string | null = null;
  let newestMs = Number.NEGATIVE_INFINITY;
  const consider = (value: string | null | undefined): void => {
    if (!value) return;
    const ms = Date.parse(value);
    if (!Number.isFinite(ms) || ms <= newestMs) return;
    newestMs = ms;
    newest = value;
  };
  for (const subscription of summary.subscriptions) {
    consider(subscription.snapshot.observed_at);
  }
  for (const device of summary.devices) {
    consider(device.last_seen_at);
    consider(device.last_observed_at);
  }
  return newest;
}

function reportingCount(devices: readonly DeviceRow[], now?: Date): number {
  return devices.filter((device) => deviceActivity(device, now).label !== "Not reporting").length;
}

export function accountStatusLine(summary: AccountSummaryRead, now?: Date): string {
  const age = updatedCopy(newestInstant(summary), now);
  const reporting = reportingCount(summary.devices, now);
  const noun = reporting === 1 ? "device" : "devices";
  return `${age} · ${reporting} ${noun} reporting`;
}

function oldestDevice(
  devices: readonly DeviceRow[],
  now?: Date,
): { display_name: string; label: string } | null {
  let oldest: { display_name: string; label: string; sinceMs: number } | null = null;
  for (const device of devices) {
    const activity = deviceActivity(device, now);
    const sinceMs = activity.since ? Date.parse(activity.since) : Number.POSITIVE_INFINITY;
    if (oldest === null || sinceMs < oldest.sinceMs) {
      oldest = { display_name: device.display_name, label: activity.label, sinceMs };
    }
  }
  return oldest;
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
