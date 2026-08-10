import {
  ACCOUNT_SCOPES,
  type AccountScope,
  DEVICE_SCOPES,
  type DeviceScope,
  type RateLimitInput,
  type RateLimitResult,
} from "@gotry-io/relay-core";

export interface RateLimitRow {
  request_count: number;
  window_expires_at: string;
}

export function encodeScopes(scopes: readonly string[], allowed: readonly string[]): string {
  if (
    scopes.length === 0 ||
    new Set(scopes).size !== scopes.length ||
    scopes.some((scope) => !allowed.includes(scope))
  ) {
    throw new Error("Session contains invalid scopes");
  }
  return JSON.stringify(scopes);
}

export function decodeAccountScopes(value: string): AccountScope[] {
  return decodeScopes(value, ACCOUNT_SCOPES) as AccountScope[];
}

export function decodeDeviceScopes(value: string): DeviceScope[] {
  return decodeScopes(value, DEVICE_SCOPES) as DeviceScope[];
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

function decodeScopes(value: string, allowed: readonly string[]): string[] {
  const parsed: unknown = JSON.parse(value);
  if (
    !Array.isArray(parsed) ||
    parsed.length === 0 ||
    new Set(parsed).size !== parsed.length ||
    parsed.some((scope) => typeof scope !== "string" || !allowed.includes(scope))
  ) {
    throw new Error("Persisted session contains invalid scopes");
  }
  return parsed as string[];
}

function parseTimestamp(value: string): number {
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) {
    throw new Error("Invalid persisted timestamp");
  }
  return timestamp;
}
