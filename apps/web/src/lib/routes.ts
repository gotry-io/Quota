import { KNOWN_PLANS } from "./plan-display.generated.ts";

export const DASHBOARD_PATH = "/my";
export const USAGE_PATH = "/my/usage";
export const DEVICES_PATH = "/my/devices";
export const SETTINGS_PATH = "/my/settings";

export function subscriptionPath(sel: string): string {
  return `/my/subscriptions/${encodeURIComponent(sel)}`;
}

export function isAccountShellPath(pathname: string): boolean {
  return pathname === DASHBOARD_PATH || pathname.startsWith(`${DASHBOARD_PATH}/`);
}

export function isSubscriptionPath(pathname: string): boolean {
  return pathname.startsWith(`${DASHBOARD_PATH}/subscriptions/`);
}

export function isUsagePath(pathname: string): boolean {
  return pathname === USAGE_PATH;
}

export function isDevicesPath(pathname: string): boolean {
  return pathname === DEVICES_PATH;
}

export function isSettingsPath(pathname: string): boolean {
  return pathname === SETTINGS_PATH;
}

export function accountPageTitle(pathname: string): string {
  if (pathname === DASHBOARD_PATH) return "Overview";
  if (pathname === USAGE_PATH) return "Usage";
  if (pathname === DEVICES_PATH) return "Devices";
  if (pathname === SETTINGS_PATH) return "Settings";
  return "Account";
}

/** Relay's GitHub sign-in. Following it is the whole flow; the browser never fetches it. */
export const SIGN_IN_PATH = "/api/auth/github/start";

/** Where to send a signed-out visitor so they come back to the page they wanted. */
export function signInHref(returnTo: string = DASHBOARD_PATH): string {
  return returnTo === DASHBOARD_PATH
    ? SIGN_IN_PATH
    : `${SIGN_IN_PATH}?return_to=${encodeURIComponent(returnTo)}`;
}

export function planDisplayName(raw: string | undefined): string | undefined {
  const value = raw?.trim();
  if (!value) return undefined;
  const known = KNOWN_PLANS[value.toLowerCase().replace(/[^\p{L}\p{N}]/gu, "")];
  if (known) return known;
  if (/[A-Z\s]/.test(value)) return value;
  return value
    .replaceAll("-", "_")
    .split("_")
    .filter(Boolean)
    .map((part) => `${part[0]?.toUpperCase()}${part.slice(1).toLowerCase()}`)
    .join(" ");
}
