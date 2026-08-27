import {
  type RateLimitInput,
  type RateLimitResult,
  SESSION_SCOPES,
  type SessionScope,
} from "@gotry-io/relay-core";

export interface RateLimitRow {
  request_count: number;
  window_expires_at: string;
}

/**
 * What each client is allowed to do, stated once.
 *
 * A browser is the only place an Account can be managed, because managing it requires a recent
 * sign-in and an exact same-origin request that only a browser makes. QuotaBar reads the Account
 * and writes its own Device. The iOS viewer only reads
 * ([ADR 0013](../../../../docs/decisions/0013-readonly-ios-account-client.md)).
 */
export const WEB_SESSION_SCOPES: readonly SessionScope[] = ["account:read", "account:manage"];
export const QUOTABAR_SESSION_SCOPES: readonly SessionScope[] = ["account:read", "device:write"];
export const IOS_SESSION_SCOPES: readonly SessionScope[] = ["account:read"];

export function encodeScopes(scopes: readonly SessionScope[]): string {
  if (
    scopes.length === 0 ||
    new Set(scopes).size !== scopes.length ||
    scopes.some((scope) => !SESSION_SCOPES.includes(scope))
  ) {
    throw new Error("Session contains invalid scopes");
  }
  return JSON.stringify(scopes);
}

export function decodeSessionScopes(value: string): SessionScope[] {
  const parsed: unknown = JSON.parse(value);
  if (
    !Array.isArray(parsed) ||
    parsed.length === 0 ||
    new Set(parsed).size !== parsed.length ||
    parsed.some(
      (scope) => typeof scope !== "string" || !SESSION_SCOPES.includes(scope as SessionScope),
    )
  ) {
    throw new Error("Persisted session contains invalid scopes");
  }
  return parsed as SessionScope[];
}

export function validateRateLimitInput(input: RateLimitInput): void {
  if (!input.key_hash || !Number.isSafeInteger(input.limit) || input.limit < 1) {
    throw new Error("Invalid rate-limit input");
  }
  const startedAt = parseTimestamp(input.window_started_at);
  const expiresAt = parseTimestamp(input.window_expires_at);
  const checkedAt = parseTimestamp(input.checked_at);
  if (startedAt >= expiresAt || checkedAt < startedAt || checkedAt >= expiresAt) {
    throw new Error("Rate-limit timestamps do not describe an active fixed window");
  }
}

export function rateLimitResult(row: RateLimitRow, input: RateLimitInput): RateLimitResult {
  const allowed = row.request_count <= input.limit;
  return {
    allowed,
    retry_after: allowed
      ? 0
      : Math.max(
          1,
          Math.ceil(
            (parseTimestamp(row.window_expires_at) - parseTimestamp(input.checked_at)) / 1000,
          ),
        ),
  };
}

function parseTimestamp(value: string): number {
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) {
    throw new Error("Invalid persisted timestamp");
  }
  return timestamp;
}
