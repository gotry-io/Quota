export const DASHBOARD_PATH = "/my";
/** Relay's GitHub sign-in. Following it is the whole flow; the browser never fetches it. */
export const SIGN_IN_PATH = "/api/auth/github/start";

/** Where to send a signed-out visitor so they come back to the page they wanted. */
export function signInHref(returnTo: string = DASHBOARD_PATH): string {
  return returnTo === DASHBOARD_PATH
    ? SIGN_IN_PATH
    : `${SIGN_IN_PATH}?return_to=${encodeURIComponent(returnTo)}`;
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
