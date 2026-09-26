import {
  CollectionRequestResponseReadSchema,
  type IdentityProvider,
  MANAGED_DATA_PROTOCOL_VERSION,
} from "@gotry-io/quota-protocol";
import { type AccountError, classifyAccountError } from "./account-errors.ts";
import {
  ACTIVITY_DAYS,
  type AccountActivityResult,
  type AccountResult,
  type AccountSummaryResult,
  type AccountUsagePeriodQuery,
  type AccountUsagePeriodResult,
  accountActivityPath,
  accountActivityRange,
  accountPath,
  accountSummaryPath,
  accountUsagePeriodPath,
  browserTimezone,
  parseAccountActivityResponse,
  parseAccountResponse,
  parseAccountSummaryBody,
  parseAccountUsagePeriodResponse,
  parseQuotaHistoryResponse,
  type QuotaHistoryResult,
  quotaHistoryPath,
  storedPeriod,
  storedPeriodETag,
  storedSummary,
  storedSummaryETag,
  storePeriod,
  storeSummary,
  usagePeriodResourceKey,
} from "./account-reads.ts";
import { DASHBOARD_PATH, SETTINGS_PATH } from "./routes.ts";

export type {
  AccountActivityResult,
  AccountError,
  AccountResult,
  AccountSummaryResult,
  AccountUsagePeriodQuery,
  AccountUsagePeriodResult,
};
export {
  ACTIVITY_DAYS,
  accountActivityPath,
  accountActivityRange,
  accountPath,
  accountSummaryPath,
  accountUsagePeriodPath,
  browserTimezone,
  usagePeriodResourceKey,
};

const jsonRequest = {
  credentials: "same-origin",
  redirect: "error",
  headers: { Accept: "application/json" },
} satisfies RequestInit;

/**
 * End this browser's session, then go where the caller says.
 *
 * Signing out from the sign-in page is how someone reaches it as nobody, so where it lands is
 * the caller's to decide rather than always the landing page.
 */
export async function signOut(destination = "/"): Promise<void> {
  const response = await fetch("/api/auth/logout", {
    method: "POST",
    ...jsonRequest,
  });
  if (!response.ok) throw new Error("logout_failed");
  window.location.assign(destination);
}

/**
 * Ask Relay to mail a one-time sign-in link. The answer does not say whether the address is an
 * identity; 202 is the only success, including when a per-address limit skipped the send.
 */
export async function requestEmailSignInLink(input: {
  email: string;
  returnTo: string;
  intent?: "sign_in" | "link";
}): Promise<"accepted" | "invalid" | "rate_limited" | "failed"> {
  try {
    const response = await fetch("/api/auth/email/start", {
      method: "POST",
      credentials: "same-origin",
      headers: { Accept: "application/json", "Content-Type": "application/json" },
      body: JSON.stringify({
        email: input.email,
        return_to: input.returnTo,
        ...(input.intent === undefined ? {} : { intent: input.intent }),
      }),
    });
    if (response.status === 202) return "accepted";
    if (response.status === 400) return "invalid";
    if (response.status === 429) return "rate_limited";
    return "failed";
  } catch {
    return "failed";
  }
}

export async function fetchAccountActivity(
  range: {
    from: string;
    to: string;
  },
  detail?: "agents" | "hours",
  timezone?: string,
): Promise<AccountActivityResult> {
  try {
    const response = await fetch(accountActivityPath(range, detail, timezone), jsonRequest);
    if (!response.ok) return classifyAccountError(response);
    return parseAccountActivityResponse(response.status, await response.json());
  } catch {
    return classifyAccountError(null);
  }
}

export async function fetchAccount(): Promise<AccountResult> {
  try {
    const response = await fetch(accountPath(), jsonRequest);
    if (!response.ok) return classifyAccountError(response);
    return parseAccountResponse(response.status, await response.json());
  } catch {
    return classifyAccountError(null);
  }
}

export async function fetchAccountUsagePeriod(
  query: AccountUsagePeriodQuery,
): Promise<AccountUsagePeriodResult> {
  const key = usagePeriodResourceKey(query);
  const etag = storedPeriodETag(key);
  const headers = etag
    ? { Accept: "application/json", "If-None-Match": etag }
    : jsonRequest.headers;
  try {
    const response = await fetch(accountUsagePeriodPath(query), {
      ...jsonRequest,
      headers,
    });
    if (response.status === 304) {
      const cached = storedPeriod(key);
      return cached ? { status: "ok", period: cached } : classifyAccountError(response);
    }
    if (!response.ok) return classifyAccountError(response);
    const parsed = parseAccountUsagePeriodResponse(response.status, await response.json());
    if (parsed.status !== "ok") return parsed;
    const nextETag = response.headers.get("ETag");
    if (nextETag) storePeriod(key, nextETag, parsed.period);
    return parsed;
  } catch {
    return classifyAccountError(null);
  }
}

export async function fetchQuotaHistory(query: {
  provider: string;
  fingerprint: string;
  since: string;
}): Promise<QuotaHistoryResult> {
  try {
    const response = await fetch(quotaHistoryPath(query), jsonRequest);
    if (!response.ok) return classifyAccountError(response);
    return parseQuotaHistoryResponse(response.status, await response.json());
  } catch {
    return classifyAccountError(null);
  }
}

export async function fetchAccountSummary(): Promise<AccountSummaryResult> {
  const etag = storedSummaryETag();
  const headers = etag
    ? { Accept: "application/json", "If-None-Match": etag }
    : jsonRequest.headers;
  try {
    const response = await fetch(accountSummaryPath(browserTimezone()), {
      ...jsonRequest,
      headers,
    });
    if (response.status === 304) {
      const cached = storedSummary();
      return cached ? { status: "ok", summary: cached } : classifyAccountError(response);
    }
    if (!response.ok) return classifyAccountError(response);
    const summary = parseAccountSummaryBody(await response.json());
    if (!summary) return classifyAccountError(null);
    const nextETag = response.headers.get("ETag");
    if (nextETag) storeSummary(nextETag, summary);
    return { status: "ok", summary };
  } catch {
    return classifyAccountError(null);
  }
}

export const COLLECTION_REQUEST_PATH = "/api/v6/account/collection-request";

/**
 * Ask the Account's Macs for a fresh reading (ADR 0063), and answer the instant Relay stored.
 *
 * A browser session may ask the same as a Device; the cookie POST carries the same-origin
 * `Origin` a browser sends on its own. Every refusal — a Relay that predates the route (404), a
 * busy session (429), anything else — is `null`, because nothing about it is shown.
 */
export async function requestCollection(): Promise<number | null> {
  try {
    const response = await fetch(COLLECTION_REQUEST_PATH, {
      method: "POST",
      credentials: "same-origin",
      redirect: "error",
      headers: { Accept: "application/json", "Content-Type": "application/json" },
      body: JSON.stringify({ protocol_version: MANAGED_DATA_PROTOCOL_VERSION }),
    });
    if (!response.ok) return null;
    const parsed = CollectionRequestResponseReadSchema.safeParse(await response.json());
    return parsed.success ? Date.parse(parsed.data.requested_at) : null;
  } catch {
    return null;
  }
}

export async function deleteDevice(
  deviceId: string,
  currentPath: string = DASHBOARD_PATH,
): Promise<"ok" | AccountError> {
  try {
    const response = await fetch(`/api/v2/account/devices/${encodeURIComponent(deviceId)}`, {
      method: "DELETE",
      ...jsonRequest,
    });
    if (response.ok) return "ok";
    return classifyAccountError(response, { destructive: true, currentPath });
  } catch {
    return classifyAccountError(null, { currentPath });
  }
}

/**
 * Unbind one channel. The last one is a conflict: an Account keeps at least one way in.
 *
 * Same ten-minute freshness as Delete Account. A stale session is recent-auth, not a forbid.
 */
export async function unlinkIdentity(
  provider: IdentityProvider,
  currentPath: string = SETTINGS_PATH,
): Promise<"ok" | "last_identity" | AccountError> {
  try {
    const response = await fetch(`/api/v2/account/identities/${encodeURIComponent(provider)}`, {
      method: "DELETE",
      ...jsonRequest,
    });
    if (response.ok) return "ok";
    if (response.status === 409) return "last_identity";
    return classifyAccountError(response, { destructive: true, currentPath });
  } catch {
    return classifyAccountError(null, { currentPath });
  }
}

export async function deleteAccount(
  currentPath: string = DASHBOARD_PATH,
): Promise<"ok" | AccountError> {
  try {
    const response = await fetch("/api/v2/account", {
      method: "DELETE",
      ...jsonRequest,
    });
    if (response.ok) return "ok";
    return classifyAccountError(response, { destructive: true, currentPath });
  } catch {
    return classifyAccountError(null, { currentPath });
  }
}
