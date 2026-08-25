/**
 * These take the fields they read rather than a whole contract type, because a reader may be
 * shown a member this build has never heard of. See ADR 0023.
 */
type CostView = { amount_microusd: string | null; status: string; basis: string };
import { remainingPercent } from "@gotry-io/quota-model";

export const WEB_LOCALE = "en-US";

export function formatCount(value: number): string {
  return new Intl.NumberFormat(WEB_LOCALE, {
    notation: "compact",
    maximumFractionDigits: 1,
  }).format(value);
}

export function formatCost(cost: CostView): string {
  if (cost.amount_microusd === null) return "—";
  const cents = (BigInt(cost.amount_microusd) + 5_000n) / 10_000n;
  const amount = `${new Intl.NumberFormat(WEB_LOCALE).format(cents / 100n)}.${(cents % 100n).toString().padStart(2, "0")}`;
  return `${cost.status === "partial" ? "≥ " : ""}$${amount}`;
}

export function costCoverage(cost: CostView): string {
  if (cost.status === "unavailable") return "Unpriced";
  const basis = cost.basis === "calculated" ? "estimated" : cost.basis;
  return cost.status === "complete" ? `${basis} · complete` : `${basis} · priced subset only`;
}

export function formatDate(value: string): string {
  return new Intl.DateTimeFormat(WEB_LOCALE, { dateStyle: "medium", timeStyle: "short" }).format(
    new Date(value),
  );
}

export function formatShortDate(value: string): string {
  return new Intl.DateTimeFormat(WEB_LOCALE, {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  }).format(new Date(`${value}T00:00:00Z`));
}

export function formatPercent(value: number): string {
  return `${new Intl.NumberFormat(WEB_LOCALE, { maximumFractionDigits: 0 }).format(value)}%`;
}

export function titleCase(value: string): string {
  return value.replaceAll("_", " ").replace(/\b\w/g, (character) => character.toUpperCase());
}

export function agentDisplayName(agent: string): string {
  switch (agent) {
    case "claude_code":
      return "Claude Code";
    case "opencode":
      return "OpenCode";
    case "pi":
      return "Pi";
    case "cursor":
      return "Cursor";
    default:
      return titleCase(agent);
  }
}

export function formatQuotaRemaining(
  window: {
    id?: string | undefined;
    used_percent: number;
    remaining_value?: number | undefined;
    limit_value?: number | undefined;
    value_unit?: string | undefined;
  },
  provider?: string,
): string {
  const percent = formatPercent(remainingPercent(window.used_percent));
  if (provider === "cursor" && window.id === "other_models") return percent;
  const absolute = formatAbsoluteRemaining(window);
  const balanceOnly = window.remaining_value !== undefined && window.limit_value === undefined;
  if (absolute === undefined) return percent;
  if (balanceOnly) return absolute;
  return `${percent} · ${absolute}`;
}

export function formatAbsoluteRemaining(window: {
  remaining_value?: number | undefined;
  value_unit?: string | undefined;
}): string | undefined {
  if (window.remaining_value === undefined) return undefined;
  if (window.value_unit === "usd") {
    return new Intl.NumberFormat(WEB_LOCALE, {
      style: "currency",
      currency: "USD",
      maximumFractionDigits: 2,
    }).format(window.remaining_value);
  }
  return `${formatCount(window.remaining_value)}${window.value_unit === "credits" ? " credits" : ""}`;
}

export function activityLevel(value: number, maximum: number): number {
  if (value <= 0 || maximum <= 0) return 0;
  return Math.min(4, Math.ceil((value / maximum) * 4));
}

/**
 * The words the dashboard shows for an observation status.
 *
 * A source that cannot read is the same problem wherever it runs, so these match what the
 * Apple clients say about a failure on the machine in front of you.
 */
export function observedSnapshotStatusLabel(status: string): string {
  switch (status) {
    case "available":
      return "Available";
    case "stale":
      return "Stale";
    case "auth_required":
      return "Sign-in needed";
    case "unavailable":
      return "Unavailable";
    case "unsupported":
      return "Unsupported";
    case "error":
      return "Can’t refresh";
    // A status this build has not heard of still names itself; it is not a reason to stop.
    default:
      return "Unknown";
  }
}
