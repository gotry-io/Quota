import {
  type AccountSummaryRead,
  type AccountUsageActivityResponseRead,
  AccountUsageActivityResponseReadSchema,
} from "@gotry-io/quota-protocol";
import { type AccountError, classifyAccountError } from "./account-errors.ts";

/**
 * The Account reads: paths, ranges, and the in-memory summary cache a 304 answers from.
 *
 * They live apart from the mutation client so node tests can exercise a request without
 * going through SvelteKit.
 */

/** How far back the activity chart asks, ending today. */
export const ACTIVITY_DAYS = 365;

export type AccountSummaryResult = { status: "ok"; summary: AccountSummaryRead } | AccountError;

export type AccountActivityResult =
  | { status: "ok"; activity: AccountUsageActivityResponseRead }
  | AccountError;

type CachedSummary = { etag: string; summary: AccountSummaryRead };

let cachedSummary: CachedSummary | null = null;

/** The ETag the next summary GET should offer back, if a previous read stored one. */
export function storedSummaryETag(): string | null {
  return cachedSummary?.etag ?? null;
}

/** The summary a matching 304 is asserting is still current. */
export function storedSummary(): AccountSummaryRead | null {
  return cachedSummary?.summary ?? null;
}

export function storeSummary(etag: string, summary: AccountSummaryRead): void {
  cachedSummary = { etag, summary };
}

export function clearStoredSummary(): void {
  cachedSummary = null;
}

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
  if (status < 200 || status >= 300) {
    return classifyAccountError(new Response(null, { status }));
  }
  const parsed = AccountUsageActivityResponseReadSchema.safeParse(body);
  return parsed.success ? { status: "ok", activity: parsed.data } : classifyAccountError(null);
}

function localDate(instant: Date): string {
  return new Intl.DateTimeFormat("en-CA", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(instant);
}
