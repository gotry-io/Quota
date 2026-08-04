import {
  OWNER_AUTH_SCOPES,
  type OwnerAuthScope,
  type OwnerSessionRecord,
  type PairingConsumeOutcome,
  type PairingDecisionOutcome,
  type RateLimitInput,
} from "@gotry-io/relay-core";

export interface OwnerSessionRow {
  owner_id: string;
  scopes_json: string;
}

export interface PairingSessionRow {
  expires_at: string;
  approved_at: string | null;
  denied_at: string | null;
  consumed_at: string | null;
}

export interface RateLimitRow {
  request_count: number;
  window_expires_at: string;
}

export function encodeOwnerScopes(scopes: OwnerAuthScope[]): string {
  const uniqueScopes = [...new Set(scopes)];
  if (
    uniqueScopes.length !== scopes.length ||
    uniqueScopes.some((scope) => !(OWNER_AUTH_SCOPES as readonly string[]).includes(scope))
  ) {
    throw new Error("Owner session contains invalid scopes");
  }
  return JSON.stringify(uniqueScopes);
}

export function decodeOwnerSession(row: OwnerSessionRow): OwnerSessionRecord {
  const value: unknown = JSON.parse(row.scopes_json);
  if (
    !Array.isArray(value) ||
    new Set(value).size !== value.length ||
    value.some(
      (scope) =>
        typeof scope !== "string" || !(OWNER_AUTH_SCOPES as readonly string[]).includes(scope),
    )
  ) {
    throw new Error("Owner session contains invalid scopes");
  }

  return {
    owner_id: row.owner_id,
    scopes: value as OwnerAuthScope[],
  };
}

export function pairingDecisionOutcome(
  row: PairingSessionRow | null,
  checkedAt: string,
): PairingDecisionOutcome | null {
  if (!row) {
    return "not_found";
  }
  if (row.consumed_at) {
    return "consumed";
  }
  if (row.approved_at || row.denied_at) {
    return "already_decided";
  }
  if (isExpired(row.expires_at, checkedAt)) {
    return "expired";
  }
  return null;
}

export function pairingUnavailableConsumeOutcome(
  row: PairingSessionRow | null,
  checkedAt: string,
): Exclude<PairingConsumeOutcome, "issued"> | null {
  if (!row) {
    return "not_found";
  }
  if (row.consumed_at) {
    return "consumed";
  }
  if (row.denied_at) {
    return "denied";
  }
  if (isExpired(row.expires_at, checkedAt)) {
    return "expired";
  }
  return row.approved_at ? null : "pending";
}

export function validateRateLimitInput(input: RateLimitInput): void {
  if (!input.key_hash) {
    throw new Error("Rate-limit key hash is required");
  }
  if (!Number.isSafeInteger(input.limit) || input.limit < 1) {
    throw new Error("Rate-limit limit must be a positive integer");
  }

  const startedAt = parseTimestamp(input.window_started_at);
  const expiresAt = parseTimestamp(input.window_expires_at);
  const checkedAt = parseTimestamp(input.checked_at);
  if (startedAt >= expiresAt || checkedAt < startedAt || checkedAt >= expiresAt) {
    throw new Error("Rate-limit timestamps must describe the active fixed window");
  }
}

export function rateLimitResult(row: RateLimitRow, input: RateLimitInput) {
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

function isExpired(expiresAt: string, checkedAt: string): boolean {
  return parseTimestamp(expiresAt) <= parseTimestamp(checkedAt);
}

function parseTimestamp(value: string): number {
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) {
    throw new Error("Invalid persisted timestamp");
  }
  return timestamp;
}
