import {
  type AccountSummary,
  AccountSummarySchema,
  DeviceAuthorizationDecisionRequestSchema,
  PROTOCOL_VERSION,
  type PublicProfile,
  PublicProfileSchema,
} from "@gotry-io/quota-protocol";
import { accountEntryAction, DASHBOARD_PATH } from "$lib/routes";

const jsonRequest = {
  credentials: "same-origin",
  redirect: "error",
  headers: { Accept: "application/json" },
} satisfies RequestInit;

export async function beginWebLogin(returnTo: string): Promise<void> {
  const response = await fetch("/api/auth/v2/sign-in/social", {
    method: "POST",
    credentials: "same-origin",
    redirect: "error",
    headers: { Accept: "application/json", "Content-Type": "application/json" },
    body: JSON.stringify({ provider: "github", callbackURL: returnTo }),
  });
  const body = (await response.json()) as { url?: unknown };
  if (!response.ok || typeof body.url !== "string") throw new Error("login_failed");
  window.location.assign(body.url);
}

export async function openAccountOrLogin(): Promise<void> {
  const response = await fetch("/api/v2/account", jsonRequest);
  switch (accountEntryAction(response.status)) {
    case "dashboard":
      window.location.assign(DASHBOARD_PATH);
      return;
    case "login":
      await beginWebLogin(DASHBOARD_PATH);
      return;
    case "error":
      throw new Error("account_probe_failed");
  }
}

export async function signOut(): Promise<void> {
  const response = await fetch("/api/auth/v2/sign-out", {
    method: "POST",
    ...jsonRequest,
  });
  if (!response.ok) throw new Error("logout_failed");
  window.location.assign("/");
}

export async function fetchAccountSummary(): Promise<
  { status: "ok"; summary: AccountSummary } | { status: "unauthorized" } | { status: "error" }
> {
  const response = await fetch(
    "/api/v2/account/summary?cost_mode=calculate&usage_agents=all&model_catalog=1",
    jsonRequest,
  );
  if (response.status === 401) return { status: "unauthorized" };
  if (!response.ok) return { status: "error" };
  const parsed = AccountSummarySchema.safeParse(await response.json());
  return parsed.success ? { status: "ok", summary: parsed.data } : { status: "error" };
}

export async function fetchPublicProfile(
  username: string,
): Promise<{ status: "ok"; profile: PublicProfile } | { status: "missing" } | { status: "error" }> {
  const response = await fetch(`/api/v2/public/profiles/${encodeURIComponent(username)}`, {
    redirect: "error",
    headers: { Accept: "application/json" },
  });
  if (response.status === 404) return { status: "missing" };
  const parsed = PublicProfileSchema.safeParse(await response.json());
  return parsed.success ? { status: "ok", profile: parsed.data } : { status: "error" };
}

export async function deleteDevice(deviceId: string): Promise<"ok" | "reauth" | "error"> {
  const response = await fetch(`/api/v2/account/devices/${encodeURIComponent(deviceId)}`, {
    method: "DELETE",
    ...jsonRequest,
  });
  if (response.status === 403) return "reauth";
  return response.ok ? "ok" : "error";
}

export async function deleteAccount(): Promise<"ok" | "reauth" | "error"> {
  const response = await fetch("/api/auth/v2/delete-user", {
    method: "POST",
    credentials: "same-origin",
    redirect: "error",
    headers: { Accept: "application/json", "Content-Type": "application/json" },
    body: "{}",
  });
  if ([400, 401, 403].includes(response.status)) return "reauth";
  return response.ok ? "ok" : "error";
}

export async function decideActivation(
  userCode: string,
  decision: "approve" | "deny",
): Promise<"ok" | "reauth" | "invalid" | "error"> {
  const request = DeviceAuthorizationDecisionRequestSchema.safeParse({
    protocol_version: PROTOCOL_VERSION,
    user_code: userCode.trim(),
    decision,
  });
  if (!request.success) return "invalid";
  const returnTo = `/activate?user_code=${encodeURIComponent(request.data.user_code)}`;
  const response = await fetch("/oauth/v2/device/authorize", {
    method: "POST",
    credentials: "same-origin",
    redirect: "error",
    headers: { Accept: "application/json", "Content-Type": "application/json" },
    body: JSON.stringify(request.data),
  });
  if (response.status === 401 || response.status === 403) {
    await beginWebLogin(returnTo);
    return "reauth";
  }
  return response.ok ? "ok" : "error";
}
