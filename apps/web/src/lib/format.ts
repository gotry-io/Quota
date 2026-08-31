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

/** How the cost was arrived at, and whether every item in it could be priced. */
export function costBasisLabel(cost: CostView): string {
  if (cost.status === "unavailable") return "Unpriced";
  const basis = cost.basis === "calculated" ? "estimated" : cost.basis;
  return cost.status === "complete" ? `${basis} · complete` : `${basis} · priced subset only`;
}

/** A future instant, such as when a window refills. Past instants use the freshness copy below. */
export function formatDate(value: string): string {
  return new Intl.DateTimeFormat(WEB_LOCALE, { dateStyle: "medium", timeStyle: "short" }).format(
    new Date(value),
  );
}

/**
 * How old a reading is, in the words every Quota client uses.
 *
 * One rule, one voice: the website, QuotaBar, and the iOS app all state age relative to now
 * rather than as a calendar date, because an absolute instant makes the reader do the
 * subtraction before they learn the only thing they wanted to know.
 * `packages/protocol/fixtures/freshness-copy-conformance.json` is the shared statement of these
 * thresholds, phrases, and when the no-reset phrase prints; this file and
 * `packages/apple-shared` both answer it.
 */
export const NO_RESET_TIME_COPY = "No reset time reported";
export const NOT_CHECKED_COPY = "Not checked";
export const NO_READINGS_COPY = "no readings yet";

/** Whether to print {@link NO_RESET_TIME_COPY} under a percent window. */
export function showsNoResetTime(remainingPercent: number, showsPercentMeter: boolean): boolean {
  return showsPercentMeter && remainingPercent < 100;
}

/** The bare compact duration: the largest whole unit that fits, with no words around it. */
function compactAge(instant: string | number | Date, now: Date = new Date()): string {
  const seconds = Math.max(0, Math.floor((now.getTime() - new Date(instant).getTime()) / 1000));
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3_600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3_600)}h`;
  if (seconds < 604_800) return `${Math.floor(seconds / 86_400)}d`;
  if (seconds < 31_536_000) return `${Math.floor(seconds / 604_800)}w`;
  return `${Math.floor(seconds / 31_536_000)}y`;
}

/**
 * The relative phrase: `just now`, `3m ago`, `2d ago`. Anything under a minute is an instant
 * rather than a ticking second count, because a number that changes while it is being read is
 * noise, not information.
 */
export function relativeAge(instant: string | number | Date, now: Date = new Date()): string {
  if (now.getTime() - new Date(instant).getTime() < 60_000) return "just now";
  return `${compactAge(instant, now)} ago`;
}

/** The whole line for a reading that still describes current quota. */
export function updatedCopy(instant: string | number | Date | null, now?: Date): string {
  if (instant === null) return NOT_CHECKED_COPY;
  return `Updated ${relativeAge(instant, now)}`;
}

/** The whole line for a reading that no longer does, naming why rather than only that it does not. */
function notCurrentCopy(reason: string, instant: string | number | Date, now?: Date): string {
  return `${reason} — last reading ${relativeAge(instant, now)}`;
}

/** The one line a surface shows under an observation. */
export function observationFreshnessCopy(status: string, observedAt: string, now?: Date): string {
  if (status === "available") return updatedCopy(observedAt, now);
  return notCurrentCopy(observedSnapshotStatusLabel(status), observedAt, now);
}

/** The age half of a device row: `Active · last reading 5m ago`. */
export function lastReadingCopy(instant: string | null, now?: Date): string {
  if (instant === null) return NO_READINGS_COPY;
  return `last reading ${relativeAge(instant, now)}`;
}

function formatPercent(value: number): string {
  return `${new Intl.NumberFormat(WEB_LOCALE, { maximumFractionDigits: 0 }).format(value)}%`;
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

function formatAbsoluteRemaining(window: {
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
function observedSnapshotStatusLabel(status: string): string {
  switch (status) {
    case "available":
      return "Available";
    case "stale":
      return "Not current";
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
