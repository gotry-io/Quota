import type { IdentityProvider } from "@gotry-io/quota-protocol";
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

/**
 * Where a visitor chooses, or confirms, which Account they are signing in as.
 *
 * Every sign-in passes through it, including the one QuotaBar and Quota for iPhone open in a
 * browser: an Account owns its identities, so which one is being reached is a question rather
 * than whatever a provider session happens to answer
 * ([ADR 0032](../../../../docs/decisions/0032-an-account-owns-its-identities.md)).
 */
export const SIGN_IN_PATH = "/sign-in";

/** Where to send a signed-out visitor so they come back to the page they wanted. */
export function signInHref(returnTo: string = DASHBOARD_PATH): string {
  return returnTo === DASHBOARD_PATH
    ? SIGN_IN_PATH
    : `${SIGN_IN_PATH}?return_to=${encodeURIComponent(returnTo)}`;
}

/**
 * Relay's round trip through one identity provider. Following it is the whole flow; the browser
 * never fetches it.
 */
export function identityStartHref(provider: IdentityProvider, returnTo: string): string {
  return `/api/auth/${provider}/start?return_to=${encodeURIComponent(returnTo)}`;
}

/**
 * The same-origin path a sign-in may return to, or null when the caller named anything else.
 *
 * Relay checks this again where it spends the value; this is what stops the page from rendering
 * a link to somewhere it would refuse to send anyone.
 */
export function signInReturnPath(value: string): string | null {
  if (
    value.length > 512 ||
    !value.startsWith("/") ||
    value.startsWith("//") ||
    /[\\\s]/.test(value)
  ) {
    return null;
  }
  return value;
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
