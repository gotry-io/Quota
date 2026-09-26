import {
  type AccountResponse,
  AccountResponseSchema,
  type AccountSummaryRead,
  AccountSummaryReadSchema,
  type AccountUsageActivityResponseRead,
  AccountUsageActivityResponseReadSchema,
  type AccountUsagePeriodResponseRead,
  AccountUsagePeriodResponseReadSchema,
  type QuotaHistoryResponseRead,
  QuotaHistoryResponseReadSchema,
  type UsagePeriodRead,
} from "@gotry-io/quota-protocol";
import { type AccountError, classifyAccountError } from "./account-errors.ts";

/**
 * The Account reads: paths, ranges, and the in-memory summary / period caches a 304 answers from.
 *
 * They live apart from the mutation client so node tests can exercise a request without
 * going through SvelteKit.
 */

/** How far back the activity chart asks, ending today. */
export const ACTIVITY_DAYS = 365;

export type AccountSummaryResult = { status: "ok"; summary: AccountSummaryRead } | AccountError;

export type AccountResult = { status: "ok"; account: AccountResponse } | AccountError;

export type AccountActivityResult =
  | { status: "ok"; activity: AccountUsageActivityResponseRead }
  | AccountError;

export type AccountUsagePeriodQuery = {
  from: string;
  to: string;
  timezone: string;
  breakdown?: boolean;
  /** `model` adds the period's usage by day and model (`model_series`). */
  series?: "model";
};

export type AccountUsagePeriodResult =
  | { status: "ok"; period: AccountUsagePeriodResponseRead }
  | AccountError;

const AccountResponseReadSchema = AccountResponseSchema.extend({
  account: AccountResponseSchema.shape.account.loose(),
}).loose();

type CachedSummary = { etag: string; summary: AccountSummaryRead };
type CachedPeriod = { etag: string; period: AccountUsagePeriodResponseRead };

let cachedSummary: CachedSummary | null = null;
const cachedPeriods = new Map<string, CachedPeriod>();

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

/**
 * The period cache key: inclusive local dates, the IANA zone, whether the agent tree was asked,
 * and whether the model series was.
 *
 * Breakdown and series are part of the key because a body without `agents` or `model_series`
 * must not answer a read that asked for them.
 */
export function usagePeriodResourceKey(query: AccountUsagePeriodQuery): string {
  return `${query.from}|${query.to}|${query.timezone}|${query.breakdown === true ? "1" : "0"}|${query.series ?? ""}`;
}

export function storedPeriodETag(key: string): string | null {
  return cachedPeriods.get(key)?.etag ?? null;
}

export function storedPeriod(key: string): AccountUsagePeriodResponseRead | null {
  return cachedPeriods.get(key)?.period ?? null;
}

export function storePeriod(
  key: string,
  etag: string,
  period: AccountUsagePeriodResponseRead,
): void {
  cachedPeriods.set(key, { etag, period });
}

export function clearStoredPeriods(): void {
  cachedPeriods.clear();
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

/** One inclusive local-date range in a required IANA zone. */
export function accountUsagePeriodPath(query: AccountUsagePeriodQuery): string {
  const params = new URLSearchParams({
    from: query.from,
    to: query.to,
    timezone: query.timezone,
  });
  if (query.breakdown === true) params.set("breakdown", "1");
  if (query.series !== undefined) params.set("series", query.series);
  return `/api/v6/account/usage/period?${params.toString()}`;
}

export type QuotaHistoryResult = { status: "ok"; history: QuotaHistoryResponseRead } | AccountError;

/**
 * One global-scope subscription's merged Account history since `since`
 * ([ADR 0062](../../../../docs/decisions/0062-quota-history-may-follow-the-account.md)).
 * Relay clamps `since` to each window's span and answers `sync: false` while the switch is off.
 */
export function quotaHistoryPath(query: {
  provider: string;
  fingerprint: string;
  since: string;
}): string {
  return `/api/v6/account/quota-history?${new URLSearchParams(query).toString()}`;
}

export function parseQuotaHistoryResponse(status: number, body: unknown): QuotaHistoryResult {
  if (status < 200 || status >= 300) {
    return classifyAccountError(new Response(null, { status }));
  }
  const parsed = QuotaHistoryResponseReadSchema.safeParse(body);
  return parsed.success ? { status: "ok", history: parsed.data } : classifyAccountError(null);
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
  const parsed = AccountSummaryReadSchema.safeParse(body);
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

export function parseAccountUsagePeriodResponse(
  status: number,
  body: unknown,
): AccountUsagePeriodResult {
  if (status < 200 || status >= 300) {
    return classifyAccountError(new Response(null, { status }));
  }
  const parsed = AccountUsagePeriodResponseReadSchema.safeParse(body);
  return parsed.success ? { status: "ok", period: parsed.data } : classifyAccountError(null);
}

/**
 * The totals, cost, and tree the Usage page already draws, taken from a period read.
 *
 * `partial` is `coverage.partial`. A body that omitted `agents` is an empty tree, not a missing
 * period.
 */
export function accountUsagePeriodView(period: AccountUsagePeriodResponseRead): UsagePeriodRead {
  return {
    totals: period.totals,
    cost: period.cost,
    cache_saved: period.cache_saved,
    partial: period.coverage.partial,
    agents: period.agents ?? [],
  };
}

/** Whether retention cut the asked local range, which the Usage page names in one line. */
export function accountUsagePeriodTruncated(period: AccountUsagePeriodResponseRead): boolean {
  return period.coverage.truncated_by_retention;
}
