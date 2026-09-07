import {
  type AccountResponse,
  AccountResponseSchema,
  type AccountSummaryRead,
  type AccountUsageActivityResponseRead,
  AccountUsageActivityResponseReadSchema,
  type RedemptionGrantDuration,
  RedeemCodeResponseSchema,
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

export type AccountResult = { status: "ok"; account: AccountResponse } | AccountError;

export type AccountActivityResult =
  | { status: "ok"; activity: AccountUsageActivityResponseRead }
  | AccountError;

const AccountResponseReadSchema = AccountResponseSchema.extend({
  account: AccountResponseSchema.shape.account.loose(),
  entitlement: AccountResponseSchema.shape.entitlement.loose(),
  purchase: AccountResponseSchema.shape.purchase.loose(),
}).loose();

const RedeemCodeResponseReadSchema = RedeemCodeResponseSchema.extend({
  entitlement: RedeemCodeResponseSchema.shape.entitlement.loose(),
  granted: RedeemCodeResponseSchema.shape.granted.loose(),
}).loose();

export type RedeemErrorCode =
  | "code_invalid"
  | "code_expired"
  | "code_already_redeemed"
  | "code_exhausted"
  | "billing_unavailable"
  | "rate_limited";

export type RedeemResult =
  | { status: "ok"; duration: RedemptionGrantDuration; campaign: string }
  | { status: "error"; code: RedeemErrorCode };

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

/** Account metadata, paid-sync entitlement, and the Web Purchase Link. */
export function accountPath(): string {
  return "/api/v2/account";
}

/** Spend a community code for Quota Pro. */
export function redeemCodePath(): string {
  return "/api/v2/account/redeem";
}

function relayErrorCode(body: unknown): string | null {
  if (typeof body !== "object" || body === null) return null;
  if (!("error" in body)) return null;
  const error = body.error;
  if (typeof error !== "object" || error === null) return null;
  if (!("code" in error)) return null;
  return typeof error.code === "string" ? error.code : null;
}

export function parseRedeemResponse(status: number, body: unknown): RedeemResult | null {
  if (status >= 200 && status < 300) {
    const parsed = RedeemCodeResponseReadSchema.safeParse(body);
    if (!parsed.success) return null;
    return {
      status: "ok",
      duration: parsed.data.granted.duration,
      campaign: parsed.data.granted.campaign,
    };
  }
  if (status === 429) return { status: "error", code: "rate_limited" };
  const code = relayErrorCode(body);
  if (status === 404 && code === "code_invalid") {
    return { status: "error", code: "code_invalid" };
  }
  if (status === 410 && code === "code_expired") {
    return { status: "error", code: "code_expired" };
  }
  if (status === 409 && code === "code_already_redeemed") {
    return { status: "error", code: "code_already_redeemed" };
  }
  if (status === 409 && code === "code_exhausted") {
    return { status: "error", code: "code_exhausted" };
  }
  if ((status === 502 || status === 503) && code === "billing_unavailable") {
    return { status: "error", code: "billing_unavailable" };
  }
  return null;
}

export function parseAccountResponse(status: number, body: unknown): AccountResult {
  if (status < 200 || status >= 300) {
    return classifyAccountError(new Response(null, { status }));
  }
  const parsed = AccountResponseReadSchema.safeParse(body);
  return parsed.success ? { status: "ok", account: parsed.data } : classifyAccountError(null);
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
