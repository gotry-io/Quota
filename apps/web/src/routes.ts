export const DASHBOARD_PATH = "/my";

export type AccountEntryAction = "dashboard" | "login" | "error";

export function accountEntryAction(status: number): AccountEntryAction {
  if (status >= 200 && status < 300) return "dashboard";
  return status === 401 ? "login" : "error";
}

/** `/app` shipped in 0.0.4; keep one bookmark redirect while `/my` is canonical. */
export function legacyDashboardRedirect(pathname: string): string | null {
  return pathname === "/app" || pathname.startsWith("/app/") ? DASHBOARD_PATH : null;
}
