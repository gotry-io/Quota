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
import { DASHBOARD_PATH, signInHref } from "./routes.ts";

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

/** Sign-in is a navigation, not a fetch: it starts on the page that asks which Account this is. */
export function beginWebLogin(returnTo: string): void {
  window.location.assign(signInHref(returnTo));
}

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

export async function fetchAccountActivity(
  range: {
    from: string;
    to: string;
  },
  detail?: "agents",
): Promise<AccountActivityResult> {
  try {
    const response = await fetch(accountActivityPath(range, detail), jsonRequest);
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
