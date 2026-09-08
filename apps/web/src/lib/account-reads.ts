import {
  type AccountResponse,
  AccountResponseSchema,
  type AccountSummaryRead,
  type AccountUsageActivityResponseRead,
  AccountUsageActivityResponseReadSchema,
  AccountSummaryReadSchema,
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

export type AccountRead = Pick<AccountResponse, "protocol_version" | "account" | "identities">;

export type AccountSummaryResult = { status: "ok"; summary: AccountSummaryRead } | AccountError;

export type AccountResult = { status: "ok"; account: AccountRead } | AccountError;

export type AccountActivityResult =
  | { status: "ok"; activity: AccountUsageActivityResponseRead }
  | AccountError;

const AccountResponseReadSchema = AccountResponseSchema.pick({
  protocol_version: true,
  account: true,
  identities: true,
})
  .extend({
    account: AccountResponseSchema.shape.account.loose(),
  })
  .loose();

const AccountSummaryViewSchema = AccountSummaryReadSchema.pick({
  protocol_version: true,
  account: true,
  devices: true,
  subscriptions: true,
  usage: true,
  pricing_revision: true,
  model_catalog_revision: true,
}).loose();

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

/** The chart's range, in UTC dates, ending on the UTC day of `today`. */
export function accountActivityRange(today: Date): { from: string; to: string } {
  const to = today.toISOString().slice(0, 10);
  const from = new Date(Date.parse(`${to}T00:00:00Z`) - (ACTIVITY_DAYS - 1) * 86_400_000);
  return { from: from.toISOString().slice(0, 10), to };
}

export function accountActivityPath(
  range: { from: string; to: string },
  detail?: "agents" | "hours",
  timezone?: string,
): string {
  const params = new URLSearchParams(range);
  if (detail !== undefined) params.set("detail", detail);
  if (timezone !== undefined) params.set("tz", timezone);
  return `/api/v6/account/usage/activity?${params.toString()}`;
}

/** The summary path, carrying the calendar this browser keeps. */
export function accountSummaryPath(timezone: string): string {
  return `/api/v6/account/summary?${new URLSearchParams({ tz: timezone }).toString()}`;
}

/** Account metadata and the identities this browser signed in with. */
export function accountPath(): string {
  return "/api/v2/account";
}

export function parseAccountResponse(status: number, body: unknown): AccountResult {
  if (status < 200 || status >= 300) {
    return classifyAccountError(new Response(null, { status }));
  }
  const parsed = AccountResponseReadSchema.safeParse(body);
  return parsed.success ? { status: "ok", account: parsed.data } : classifyAccountError(null);
}

export function parseAccountSummaryBody(body: unknown): AccountSummaryRead | null {
  const parsed = AccountSummaryViewSchema.safeParse(body);
  return parsed.success ? (parsed.data as AccountSummaryRead) : null;
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
