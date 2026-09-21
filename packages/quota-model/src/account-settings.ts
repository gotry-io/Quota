import {
  type AccountSettings,
  AccountSettingsSchema,
  DEFAULT_ACCOUNT_SETTINGS,
} from "@gotry-io/quota-protocol";

export type NormalizeAccountSettingsResult = { ok: AccountSettings } | { refused: true };

/**
 * One spelling per amount: no leading zeros and exactly two fraction digits.
 *
 * The wire accepts `"0.5"`, `"0.50"` and `"00.5"` for the same fifty cents, and three runtimes write
 * this field. Swift can only write cents, because `Decimal` does not keep a scale; a writer that
 * passed the text through would make the stored document depend on who wrote it last. Text in, text
 * out — never through a float.
 */
export function canonicalAmountUSD(amount: string): string {
  const [whole = "0", fraction = ""] = amount.split(".");
  return `${whole.replace(/^0+(?=\d)/, "")}.${fraction.padEnd(2, "0")}`;
}

/** The stored document, or a refusal when the input is not that document. */
export function normalizeAccountSettings(input: unknown): NormalizeAccountSettingsResult {
  const parsed = AccountSettingsSchema.safeParse(input);
  if (!parsed.success) return { refused: true };
  const amount = parsed.data.budget.amount_usd;
  return {
    ok: {
      alerts: parsed.data.alerts,
      budget: {
        amount_usd: amount === null ? null : canonicalAmountUSD(amount),
        alerts: parsed.data.budget.alerts,
      },
    },
  };
}

export type FirstSyncAction = "seed" | "adopt" | "adopt_and_merge";

export type FirstSyncAccountDocument = {
  revision: number;
  alerts: AccountSettings["alerts"];
  budget: AccountSettings["budget"];
};

export type FirstSyncPlan = {
  action: FirstSyncAction;
  local: AccountSettings;
  write: AccountSettings | null;
};

/**
 * What a device does the first time it holds local policy and an Account document.
 *
 * Revision 0 is no row. Non-default local values seed it; defaults write nothing. A row wins
 * for every policy field, and local thresholds for selectors the Account does not name are
 * merged in once.
 */
export function planFirstSync(
  local: AccountSettings,
  account: FirstSyncAccountDocument,
): FirstSyncPlan {
  if (account.revision === 0) {
    if (isDefaultAccountSettings(local)) {
      return { action: "adopt", local: cloneAccountSettings(local), write: null };
    }
    const seeded = cloneAccountSettings(local);
    return { action: "seed", local: seeded, write: cloneAccountSettings(seeded) };
  }
  const extras = extraThresholds(local.alerts.thresholds, account.alerts.thresholds);
  const adopted: AccountSettings = {
    alerts: {
      reset_reminders: account.alerts.reset_reminders,
      pace_alerts: account.alerts.pace_alerts,
      thresholds: { ...account.alerts.thresholds, ...extras },
    },
    budget: {
      amount_usd: account.budget.amount_usd,
      alerts: account.budget.alerts,
    },
  };
  if (Object.keys(extras).length === 0) {
    return { action: "adopt", local: adopted, write: null };
  }
  return {
    action: "adopt_and_merge",
    local: adopted,
    write: cloneAccountSettings(adopted),
  };
}

export type AccountSettingsEdit =
  | { kind: "set_thresholds"; selector: string; thresholds: readonly number[] }
  | { kind: "set_reset_reminders"; value: boolean }
  | { kind: "set_pace_alerts"; value: boolean }
  | { kind: "set_budget_amount"; value: string | null }
  | { kind: "set_budget_alerts"; value: boolean };

/**
 * Replay one local edit onto the document a 412 just returned. Selectors the editor does not
 * recognise are copied through.
 */
export function reapplyEdit(edit: AccountSettingsEdit, fresh: AccountSettings): AccountSettings {
  const next = cloneAccountSettings(fresh);
  switch (edit.kind) {
    case "set_thresholds":
      next.alerts.thresholds[edit.selector] = [...edit.thresholds];
      return next;
    case "set_reset_reminders":
      next.alerts.reset_reminders = edit.value;
      return next;
    case "set_pace_alerts":
      next.alerts.pace_alerts = edit.value;
      return next;
    case "set_budget_amount":
      next.budget.amount_usd = edit.value;
      return next;
    case "set_budget_alerts":
      next.budget.alerts = edit.value;
      return next;
  }
}

export function isDefaultAccountSettings(settings: AccountSettings): boolean {
  return (
    settings.alerts.reset_reminders === DEFAULT_ACCOUNT_SETTINGS.alerts.reset_reminders &&
    settings.alerts.pace_alerts === DEFAULT_ACCOUNT_SETTINGS.alerts.pace_alerts &&
    Object.keys(settings.alerts.thresholds).length === 0 &&
    settings.budget.amount_usd === DEFAULT_ACCOUNT_SETTINGS.budget.amount_usd &&
    settings.budget.alerts === DEFAULT_ACCOUNT_SETTINGS.budget.alerts
  );
}

function extraThresholds(
  local: AccountSettings["alerts"]["thresholds"],
  account: AccountSettings["alerts"]["thresholds"],
): AccountSettings["alerts"]["thresholds"] {
  const extras: AccountSettings["alerts"]["thresholds"] = {};
  for (const [selector, thresholds] of Object.entries(local)) {
    if (account[selector] === undefined) extras[selector] = [...thresholds];
  }
  return extras;
}

function cloneAccountSettings(settings: AccountSettings): AccountSettings {
  const thresholds: AccountSettings["alerts"]["thresholds"] = {};
  for (const [selector, values] of Object.entries(settings.alerts.thresholds)) {
    thresholds[selector] = [...values];
  }
  return {
    alerts: {
      reset_reminders: settings.alerts.reset_reminders,
      pace_alerts: settings.alerts.pace_alerts,
      thresholds,
    },
    budget: {
      amount_usd: settings.budget.amount_usd,
      alerts: settings.budget.alerts,
    },
  };
}
