import { type AccountSettingsEdit, reapplyEdit } from "@gotry-io/quota-model";
import {
  ACCOUNT_SETTINGS_UNSET_UPDATED_AT,
  type AccountSettings,
  type AccountSettingsResponseRead,
  AccountSettingsResponseReadSchema,
  DEFAULT_ACCOUNT_SETTINGS,
  PROTOCOL_VERSION,
} from "@gotry-io/quota-protocol";
import { type AccountError, classifyAccountError } from "./account-errors.ts";
import { USAGE_PATH } from "./routes.ts";

export const ACCOUNT_SETTINGS_PATH = "/api/v2/account/settings";

/** A second stale `If-Match` after one replay. The document changed again. */
export const SETTINGS_CHANGED_ELSEWHERE_COPY = "Changed elsewhere, try again.";

const jsonRequest = {
  credentials: "same-origin",
  redirect: "error",
  headers: { Accept: "application/json" },
} satisfies RequestInit;

const usagePath = { currentPath: USAGE_PATH } as const;

export type BudgetEdit = Extract<
  AccountSettingsEdit,
  { kind: "set_budget_amount" } | { kind: "set_budget_alerts" }
>;

export type AccountSettingsOk = {
  status: "ok";
  settings: AccountSettingsResponseRead;
  etag: string;
};

export type AccountSettingsResult =
  | AccountSettingsOk
  | { status: "not_modified"; settings: AccountSettingsResponseRead; etag: string }
  | { status: "stale"; settings: AccountSettingsResponseRead; etag: string }
  | { status: "conflict"; message: string; settings: AccountSettingsResponseRead; etag: string }
  | { status: "error"; error: AccountError };

let lastSettings: AccountSettingsResponseRead | null = null;
let lastETag: string | null = null;

/** The default document Relay answers when the Account has no row. */
export function defaultAccountSettingsResponse(): AccountSettingsResponseRead {
  return {
    protocol_version: PROTOCOL_VERSION,
    revision: 0,
    updated_at: ACCOUNT_SETTINGS_UNSET_UPDATED_AT,
    alerts: {
      reset_reminders: DEFAULT_ACCOUNT_SETTINGS.alerts.reset_reminders,
      pace_alerts: DEFAULT_ACCOUNT_SETTINGS.alerts.pace_alerts,
      thresholds: { ...DEFAULT_ACCOUNT_SETTINGS.alerts.thresholds },
    },
    budget: {
      amount_usd: DEFAULT_ACCOUNT_SETTINGS.budget.amount_usd,
      alerts: DEFAULT_ACCOUNT_SETTINGS.budget.alerts,
    },
  };
}

export function storedAccountSettings(): AccountSettingsResponseRead | null {
  return lastSettings;
}

export function storedAccountSettingsETag(): string | null {
  return lastETag;
}

export function clearStoredAccountSettings(): void {
  lastSettings = null;
  lastETag = null;
}

/**
 * `GET /api/v2/account/settings`. Parses with the tolerant read schema and keeps the ETag
 * for a later `If-Match` write. A matching `If-None-Match` is 304.
 */
export async function fetchAccountSettings(): Promise<AccountSettingsResult> {
  const headers = lastETag
    ? { Accept: "application/json", "If-None-Match": lastETag }
    : jsonRequest.headers;
  try {
    const response = await fetch(ACCOUNT_SETTINGS_PATH, { ...jsonRequest, headers });
    if (response.status === 304) {
      if (!lastSettings || !lastETag) {
        return { status: "error", error: classifyAccountError(response, usagePath) };
      }
      return { status: "not_modified", settings: lastSettings, etag: lastETag };
    }
    if (!response.ok) {
      return { status: "error", error: classifyAccountError(response, usagePath) };
    }
    return remember(response, await response.json(), "ok");
  } catch {
    return { status: "error", error: classifyAccountError(null, usagePath) };
  }
}

/**
 * Replace the stored document. `If-Match` is the last ETag. A 412 returns the current
 * document as `stale` so the caller can replay one edit or adopt.
 */
export async function writeAccountSettings(
  settings: AccountSettings,
): Promise<AccountSettingsResult> {
  const etag = lastETag;
  if (!etag) {
    return { status: "error", error: classifyAccountError(null, usagePath) };
  }
  try {
    const response = await fetch(ACCOUNT_SETTINGS_PATH, {
      ...jsonRequest,
      method: "PUT",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "If-Match": etag,
      },
      body: JSON.stringify({
        protocol_version: PROTOCOL_VERSION,
        alerts: settings.alerts,
        budget: settings.budget,
      }),
    });
    if (response.status === 412) {
      return remember(response, await response.json(), "stale");
    }
    if (!response.ok) {
      return { status: "error", error: classifyAccountError(response, usagePath) };
    }
    return remember(response, await response.json(), "ok");
  } catch {
    return { status: "error", error: classifyAccountError(null, usagePath) };
  }
}

/**
 * Write one budget field. On 412, re-apply that edit onto the fresh document and retry once.
 * A second 412 is `conflict`: changed elsewhere, try again.
 */
export async function saveBudget(edit: BudgetEdit): Promise<AccountSettingsResult> {
  if (!lastSettings || !lastETag) {
    const fetched = await fetchAccountSettings();
    if (fetched.status === "error") return fetched;
  }
  const first = await writeEdited(edit);
  if (first.status !== "stale") return first;
  const second = await writeEdited(edit);
  if (second.status === "stale") {
    return {
      status: "conflict",
      message: SETTINGS_CHANGED_ELSEWHERE_COPY,
      settings: second.settings,
      etag: second.etag,
    };
  }
  return second;
}

async function writeEdited(edit: BudgetEdit): Promise<AccountSettingsResult> {
  if (!lastSettings) {
    return { status: "error", error: classifyAccountError(null, usagePath) };
  }
  return writeAccountSettings(reapplyEdit(edit, storedDocument(lastSettings)));
}

function storedDocument(settings: AccountSettingsResponseRead): AccountSettings {
  return {
    alerts: {
      reset_reminders: settings.alerts.reset_reminders,
      pace_alerts: settings.alerts.pace_alerts,
      thresholds: { ...settings.alerts.thresholds },
    },
    budget: {
      amount_usd: settings.budget.amount_usd,
      alerts: settings.budget.alerts,
    },
  };
}

function remember(
  response: Response,
  body: unknown,
  status: "ok" | "stale",
): AccountSettingsResult {
  const parsed = AccountSettingsResponseReadSchema.safeParse(body);
  if (!parsed.success) {
    return { status: "error", error: classifyAccountError(null, usagePath) };
  }
  const etag = response.headers.get("ETag") || `"${parsed.data.revision}"`;
  lastSettings = parsed.data;
  lastETag = etag;
  return { status, settings: parsed.data, etag };
}
