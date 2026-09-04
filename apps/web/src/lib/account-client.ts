import { AccountSummaryReadSchema } from "@gotry-io/quota-protocol";
import { type AccountError, classifyAccountError } from "./account-errors.ts";
import {
  type AccountActivityResult,
  type AccountSummaryResult,
  accountActivityPath,
  accountActivityRange,
  accountSummaryPath,
  ACTIVITY_DAYS,
  browserTimezone,
  parseAccountActivityResponse,
  storedSummary,
  storedSummaryETag,
  storeSummary,
} from "./account-reads.ts";
import { signInHref } from "./routes.ts";

export type { AccountActivityResult, AccountError, AccountSummaryResult };
export {
  accountActivityPath,
  accountActivityRange,
  accountSummaryPath,
  ACTIVITY_DAYS,
  browserTimezone,
};

const jsonRequest = {
  credentials: "same-origin",
  redirect: "error",
  headers: { Accept: "application/json" },
} satisfies RequestInit;

/** Sign-in is a navigation, not a fetch: Relay answers it with a redirect to GitHub. */
export function beginWebLogin(returnTo: string): void {
  window.location.assign(signInHref(returnTo));
}

export async function signOut(): Promise<void> {
  const response = await fetch("/api/auth/logout", {
    method: "POST",
    ...jsonRequest,
  });
  if (!response.ok) throw new Error("logout_failed");
  window.location.assign("/");
}

export async function fetchAccountActivity(range: {
  from: string;
  to: string;
}): Promise<AccountActivityResult> {
  try {
    const response = await fetch(accountActivityPath(range), jsonRequest);
    if (!response.ok) return classifyAccountError(response);
    return parseAccountActivityResponse(response.status, await response.json());
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
    const parsed = AccountSummaryReadSchema.safeParse(await response.json());
    if (!parsed.success) return classifyAccountError(null);
    const nextETag = response.headers.get("ETag");
    if (nextETag) storeSummary(nextETag, parsed.data);
    return { status: "ok", summary: parsed.data };
  } catch {
    return classifyAccountError(null);
  }
}

export async function deleteDevice(deviceId: string): Promise<"ok" | AccountError> {
  try {
    const response = await fetch(`/api/v2/account/devices/${encodeURIComponent(deviceId)}`, {
      method: "DELETE",
      ...jsonRequest,
    });
    if (response.ok) return "ok";
    return classifyAccountError(response, { destructive: true });
  } catch {
    return classifyAccountError(null);
  }
}

export async function deleteAccount(): Promise<"ok" | AccountError> {
  try {
    const response = await fetch("/api/v2/account", {
      method: "DELETE",
      ...jsonRequest,
    });
    if (response.ok) return "ok";
    return classifyAccountError(response, { destructive: true });
  } catch {
    return classifyAccountError(null);
  }
}
