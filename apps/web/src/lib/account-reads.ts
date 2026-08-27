import {
  type AccountUsageActivityResponseRead,
  AccountUsageActivityResponseReadSchema,
} from "@gotry-io/quota-protocol";

/**
 * The Account reads, stated as the paths and ranges they ask for.
 *
 * They live apart from the rest of the client because a request builder is worth testing on
 * its own, and the rest of that file reaches into SvelteKit's `$lib` alias.
 */

/** How far back the activity chart asks, ending today. */
export const ACTIVITY_DAYS = 365;

export type AccountActivityResult =
  | { status: "ok"; activity: AccountUsageActivityResponseRead }
  | { status: "unauthorized" }
  | { status: "error" };

/** The chart's range, in dates, ending on the day the browser is having. */
export function accountActivityRange(today: Date): { from: string; to: string } {
  const to = localDate(today);
  const from = new Date(Date.parse(`${to}T00:00:00Z`) - (ACTIVITY_DAYS - 1) * 86_400_000);
  return { from: from.toISOString().slice(0, 10), to };
}

export function accountActivityPath(range: { from: string; to: string }): string {
  return `/api/v6/account/usage/activity?${new URLSearchParams(range).toString()}`;
}

/** The summary path, carrying the calendar this browser keeps. */
export function accountSummaryPath(timezone: string): string {
  return `/api/v6/account/summary?${new URLSearchParams({ tz: timezone }).toString()}`;
}

export function browserTimezone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
}

export function parseAccountActivityResponse(status: number, body: unknown): AccountActivityResult {
  if (status === 401) return { status: "unauthorized" };
  if (status < 200 || status >= 300) return { status: "error" };
  const parsed = AccountUsageActivityResponseReadSchema.safeParse(body);
  return parsed.success ? { status: "ok", activity: parsed.data } : { status: "error" };
}

function localDate(instant: Date): string {
  return new Intl.DateTimeFormat("en-CA", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(instant);
}
