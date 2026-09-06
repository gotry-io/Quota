import {
  PROTOCOL_VERSION,
  type PublicProfile,
  PublicProfileResponseReadSchema,
  type PublicProfileUpdate,
} from "@gotry-io/quota-protocol";
import { type AccountError, classifyAccountError } from "./account-errors.ts";
import { SETTINGS_PATH } from "./routes.ts";

const PUBLIC_PROFILE_PATH = "/api/v2/account/profile";

const jsonRequest = {
  credentials: "same-origin",
  redirect: "error",
  headers: { Accept: "application/json" },
} satisfies RequestInit;

/** Relay answered, but the handle belongs to another Account. */
export const HANDLE_TAKEN_COPY = "That handle is already taken.";

export type PublicProfileResult =
  | { status: "ok"; profile: PublicProfile }
  | { status: "handle_taken" }
  | { status: "error"; error: AccountError };

export async function fetchPublicProfile(): Promise<PublicProfileResult> {
  try {
    const response = await fetch(PUBLIC_PROFILE_PATH, jsonRequest);
    if (!response.ok) {
      return { status: "error", error: classifyAccountError(response, settingsPath) };
    }
    return parsePublicProfile(await response.json());
  } catch {
    return { status: "error", error: classifyAccountError(null, settingsPath) };
  }
}

export async function savePublicProfile(
  profile: PublicProfileUpdate,
): Promise<PublicProfileResult> {
  try {
    const response = await fetch(PUBLIC_PROFILE_PATH, {
      ...jsonRequest,
      method: "PUT",
      headers: { ...jsonRequest.headers, "Content-Type": "application/json" },
      body: JSON.stringify({ protocol_version: PROTOCOL_VERSION, profile }),
    });
    if (response.status === 409) return { status: "handle_taken" };
    if (!response.ok) {
      return { status: "error", error: classifyAccountError(response, settingsPath) };
    }
    return parsePublicProfile(await response.json());
  } catch {
    return { status: "error", error: classifyAccountError(null, settingsPath) };
  }
}

const settingsPath = { currentPath: SETTINGS_PATH } as const;

function parsePublicProfile(body: unknown): PublicProfileResult {
  const parsed = PublicProfileResponseReadSchema.safeParse(body);
  if (!parsed.success) return { status: "error", error: classifyAccountError(null, settingsPath) };
  return { status: "ok", profile: parsed.data.profile };
}
