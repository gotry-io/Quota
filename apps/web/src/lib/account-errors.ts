import { DASHBOARD_PATH, SIGN_IN_PATH, signInHref } from "./routes.ts";

export type AccountErrorStatus =
  | "session_ended"
  | "recent_auth_required"
  | "forbidden"
  | "unavailable";

export type AccountErrorAction = { type: "sign_in"; href: string } | { type: "retry" };

export type AccountError = {
  status: AccountErrorStatus;
  message: string;
  action: AccountErrorAction | null;
};

export const SESSION_ENDED_COPY = "Your session ended. Sign in again.";
export const RECENT_AUTH_COPY = "Sign in again to confirm this change.";
export const FORBIDDEN_COPY = "You don't have permission to do that.";
export const UNAVAILABLE_COPY = "Quota couldn't load this. Retry.";

/**
 * Classify a Relay response (or a failed fetch) into the dashboard's four error states.
 *
 * Destructive mutations treat 403 as recent authentication rather than a hard forbid, because
 * Relay answers a stale web session the same way it answers a missing scope.
 */
export function classifyAccountError(
  response: Response | null,
  options: { destructive?: boolean; currentPath?: string } = {},
): AccountError {
  const currentPath = options.currentPath ?? DASHBOARD_PATH;
  const status = response?.status;

  if (status === 401) {
    return {
      status: "session_ended",
      message: SESSION_ENDED_COPY,
      action: { type: "sign_in", href: signInHref(currentPath) },
    };
  }

  if (status === 403 && options.destructive) {
    return {
      status: "recent_auth_required",
      message: RECENT_AUTH_COPY,
      action: {
        type: "sign_in",
        href: `${SIGN_IN_PATH}?return_to=${encodeURIComponent(currentPath)}`,
      },
    };
  }

  if (status === 403) {
    return {
      status: "forbidden",
      message: FORBIDDEN_COPY,
      action: null,
    };
  }

  return {
    status: "unavailable",
    message: UNAVAILABLE_COPY,
    action: { type: "retry" },
  };
}

export function accountNoticeActionLabel(error: AccountError): string {
  return error.action?.type === "sign_in" ? "Sign in" : "Retry";
}

export function accountNoticeRetry(
  error: AccountError,
  retry: () => void,
): (() => void) | undefined {
  if (error.action?.type === "sign_in") {
    const href = error.action.href;
    return () => {
      window.location.assign(href);
    };
  }
  if (error.action?.type === "retry") return retry;
  return undefined;
}
