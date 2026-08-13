export const DASHBOARD_PATH = "/my";
export const PUBLIC_PROFILE_PATH = /^\/u\/([a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?)$/;

export function publicProfileUsername(pathname: string): string | null {
  const match = PUBLIC_PROFILE_PATH.exec(pathname);
  return match?.[1] ?? null;
}

export type AccountEntryAction = "dashboard" | "login" | "error";

export function accountEntryAction(status: number): AccountEntryAction {
  if (status >= 200 && status < 300) return "dashboard";
  return status === 401 ? "login" : "error";
}

/** `/app` shipped in 0.0.4; keep one bookmark redirect while `/my` is canonical. */
export function legacyDashboardRedirect(pathname: string): string | null {
  return pathname === "/app" || pathname.startsWith("/app/") ? DASHBOARD_PATH : null;
}

const KNOWN_PLANS: Readonly<Record<string, string>> = {
  free: "Free",
  plus: "Plus",
  pro: "Pro",
  prolite: "Pro Lite",
  pro_lite: "Pro Lite",
  "pro-lite": "Pro Lite",
  max: "Max",
  team: "Team",
  business: "Business",
  enterprise: "Enterprise",
  edu: "Edu",
  education: "Education",
  supergrok: "SuperGrok",
  super_grok: "SuperGrok",
  "super-grok": "SuperGrok",
  super: "Super",
};

export function planDisplayName(raw: string | undefined): string | undefined {
  const value = raw?.trim();
  if (!value) return undefined;
  const known = KNOWN_PLANS[value.toLowerCase().replaceAll(" ", "")];
  if (known) return known;
  if (/[A-Z\s]/.test(value)) return value;
  return value
    .replaceAll("-", "_")
    .split("_")
    .filter(Boolean)
    .map((part) => `${part[0]?.toUpperCase()}${part.slice(1).toLowerCase()}`)
    .join(" ");
}
