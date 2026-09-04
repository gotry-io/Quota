/**
 * These take the fields they read rather than a whole contract type, because a reader may be
 * shown a member this build has never heard of. See ADR 0023.
 */
type CostView = { amount_microusd: string | null; status: string; basis: string };
import { USAGE_OTHER_MODEL } from "@gotry-io/quota-protocol";
import {
  isBalanceOnly,
  remainingPercent,
  showsPercentMeter as windowShowsPercentMeter,
} from "@gotry-io/quota-model";

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

/** The overflow leaf a period folds leftover models into. */
export function usageModelDisplayName(model: string): string {
  return model === USAGE_OTHER_MODEL ? "Other" : model;
}

/** How the cost was arrived at, and whether every item in it could be priced. */
export function costBasisLabel(cost: CostView): string {
  if (cost.status === "unavailable") return "Unpriced";
  const basis = cost.basis === "calculated" ? "estimated" : cost.basis;
  return cost.status === "complete" ? `${basis} · complete` : `${basis} · priced subset only`;
}

/**
 * How old a reading is, and when a window refills, in the words every Quota client uses.
 *
 * One rule, one voice: the website, QuotaBar, and the iOS app all state age relative to now
 * rather than as a calendar date, because an absolute instant makes the reader do the
 * subtraction before they learn the only thing they wanted to know. A future refill is the
 * exception: it is a countdown or a local date, never an age.
 * `packages/protocol/fixtures/freshness-copy-conformance.json` is the shared statement of these
 * thresholds, phrases, when the no-reset phrase prints, and how a future refill is named; this
 * file and `packages/apple-shared` both answer it.
 */
export const NO_RESET_TIME_COPY = "No reset time reported";
export const NOT_CHECKED_COPY = "Not checked";
export const NO_READINGS_COPY = "no readings yet";

type RemainingWindow = {
  used_percent: number;
  remaining_value?: number | undefined;
  limit_value?: number | undefined;
};

/** Whether to print {@link NO_RESET_TIME_COPY} under a percent window. */
export function showsNoResetTime(remainingPercent: number, showsPercentMeter: boolean): boolean;
export function showsNoResetTime(window: RemainingWindow): boolean;
export function showsNoResetTime(
  remainingPercentOrWindow: number | RemainingWindow,
  showsPercentMeter?: boolean,
): boolean {
  if (typeof remainingPercentOrWindow !== "number") {
    return showsNoResetTime(
      remainingPercent(remainingPercentOrWindow.used_percent),
      windowShowsPercentMeter(remainingPercentOrWindow),
    );
  }
  return Boolean(showsPercentMeter) && remainingPercentOrWindow < 100;
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

/**
 * The line under a window that still has a future refill, or `null` once that instant has passed.
 *
 * English is fixed; `timeZone` is the IANA zone the reader is in. Minutes round up, and a
 * duration under a minute still reads as `Resets in 1m`.
 */
export function resetCopy(
  resetsAt: string | number | Date,
  now: Date = new Date(),
  timeZone: string = Intl.DateTimeFormat().resolvedOptions().timeZone,
): string | null {
  const resetDate = new Date(resetsAt);
  const seconds = (resetDate.getTime() - now.getTime()) / 1000;
  if (!(seconds > 0)) return null;
  const wholeMinutes = Math.max(1, Math.ceil(seconds / 60));
  if (wholeMinutes < 60) {
    return `Resets in ${wholeMinutes}m`;
  }
  if (seconds < 86_400) {
    let hours = Math.floor(seconds / 3_600);
    let minutes = Math.ceil((seconds - hours * 3_600) / 60);
    if (minutes === 60) {
      hours += 1;
      minutes = 0;
    }
    if (minutes === 0) return `Resets in ${hours}h`;
    return `Resets in ${hours}h ${minutes}m`;
  }
  const parts = zonedDateParts(resetDate, timeZone);
  if (seconds < 604_800) {
    return `Resets ${parts.weekday} ${parts.hour}:${parts.minute}`;
  }
  return `Resets ${parts.month} ${parts.day}`;
}

function zonedDateParts(
  date: Date,
  timeZone: string,
): { weekday: string; month: string; day: string; hour: string; minute: string } {
  const values = new Map<string, string>();
  for (const part of new Intl.DateTimeFormat("en-US", {
    timeZone,
    weekday: "short",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date)) {
    if (part.type !== "literal") values.set(part.type, part.value);
  }
  return {
    weekday: values.get("weekday") ?? "",
    month: values.get("month") ?? "",
    day: values.get("day") ?? "",
    hour: (values.get("hour") ?? "00").padStart(2, "0"),
    minute: (values.get("minute") ?? "00").padStart(2, "0"),
  };
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
  const balanceOnly = isBalanceOnly(window);
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
