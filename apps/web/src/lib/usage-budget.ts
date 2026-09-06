import type { UsageCostOutcomeRead } from "@gotry-io/quota-protocol";

/**
 * A monthly API-equivalent spend budget, which is this browser's own preference.
 *
 * It is never uploaded: a budget says what someone wants to be warned about, which is not a fact
 * about their Account. The website keeps it in `localStorage`; both Apple apps keep the same two
 * fields in `UserDefaults`. A crossing is announced once per month per threshold, keyed the way
 * `QuotaAlerts` keys a fired alert: the month is the window and the share is the threshold.
 */
export interface UsageBudget {
  /** Null means no budget is set, which is the state a browser starts in. */
  amountUSD: number | null;
  /** Whether crossing 80% and 100% of the amount says so on the page. */
  alerts: boolean;
}

export interface UsageBudgetProgress {
  spentUSD: number;
  budgetUSD: number;
  /** Whole percent, rounded down, so 99.9% of a budget never reads as spent. */
  percent: number;
  /** The bar's fill: a month past its budget fills it once, not twice. */
  fraction: number;
  /** Whether the priced share of the month is short, which makes the spend a lower bound. */
  partial: boolean;
  text: string;
}

export const BUDGET_WARNING_PERCENT = 80;
export const BUDGET_EXHAUSTED_PERCENT = 100;
export const BUDGET_THRESHOLDS = [BUDGET_WARNING_PERCENT, BUDGET_EXHAUSTED_PERCENT];
/** The widest budget the editor accepts, which keeps the progress text one line. */
export const MAXIMUM_BUDGET_USD = 1_000_000;

export const NO_BUDGET: UsageBudget = { amountUSD: null, alerts: true };

const AMOUNT_KEY = "quota.usage.budget.amount";
const ALERTS_KEY = "quota.usage.budget.alerts";
const FIRED_KEY = "quota.usage.budget.fired";

/** The store a browser keeps its budget in, and nothing at all while rendering on the server. */
export function usageBudgetStorage(): Storage | null {
  return typeof localStorage === "undefined" ? null : localStorage;
}

/** An amount outside `(0, maximum]` is no budget at all rather than a budget of zero. */
export function normalizedBudgetAmount(amount: number | null): number | null {
  if (amount === null || !Number.isFinite(amount) || amount <= 0 || amount > MAXIMUM_BUDGET_USD) {
    return null;
  }
  return Math.round(amount * 100) / 100;
}

export function readBudget(storage: Storage | null): UsageBudget {
  if (!storage) return NO_BUDGET;
  const amount = storage.getItem(AMOUNT_KEY);
  return {
    amountUSD: normalizedBudgetAmount(amount === null ? null : Number(amount)),
    alerts: storage.getItem(ALERTS_KEY) !== "off",
  };
}

export function writeBudget(storage: Storage | null, budget: UsageBudget): UsageBudget {
  const normalized: UsageBudget = {
    amountUSD: normalizedBudgetAmount(budget.amountUSD),
    alerts: budget.alerts,
  };
  if (storage) {
    if (normalized.amountUSD === null) storage.removeItem(AMOUNT_KEY);
    else storage.setItem(AMOUNT_KEY, String(normalized.amountUSD));
    storage.setItem(ALERTS_KEY, normalized.alerts ? "on" : "off");
  }
  return normalized;
}

/** The dollars an `amount_microusd` names, which is how every Usage cost is carried. */
export function costDollars(cost: UsageCostOutcomeRead): number {
  return cost.amount_microusd === null ? 0 : Number(cost.amount_microusd) / 1_000_000;
}

export function budgetProgress(
  spentUSD: number,
  budgetUSD: number,
  partial: boolean,
): UsageBudgetProgress {
  const percent = Math.max(0, Math.floor((spentUSD / budgetUSD) * 100));
  return {
    spentUSD,
    budgetUSD,
    percent,
    fraction: Math.min(1, percent / 100),
    partial,
    text: `${partial ? "≥ " : ""}${usd(spentUSD)} / ${usd(budgetUSD)} · ${percent}%`,
  };
}

/** `YYYY-MM` in this browser's own calendar, which is the cycle a monthly budget runs on. */
export function budgetMonth(today: Date): string {
  return `${String(today.getFullYear()).padStart(4, "0")}-${String(today.getMonth() + 1).padStart(2, "0")}`;
}

/** `budget:<month>:<threshold>`, the one key a crossing fires under. */
export function budgetAlertKey(month: string, threshold: number): string {
  return `budget:${month}:${threshold}`;
}

export function readFiredBudgetAlerts(storage: Storage | null): string[] {
  const raw = storage?.getItem(FIRED_KEY);
  if (!raw) return [];
  try {
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter((value) => typeof value === "string") : [];
  } catch {
    return [];
  }
}

export function writeFiredBudgetAlerts(storage: Storage | null, keys: readonly string[]): void {
  storage?.setItem(FIRED_KEY, JSON.stringify([...keys]));
}

/** The thresholds this month has reached that have not been announced yet, lowest first. */
export function pendingBudgetAlerts(
  budget: UsageBudget,
  progress: UsageBudgetProgress | null,
  month: string,
  fired: readonly string[],
): number[] {
  if (!budget.alerts || budget.amountUSD === null || !progress) return [];
  return BUDGET_THRESHOLDS.filter(
    (threshold) =>
      progress.percent >= threshold && !fired.includes(budgetAlertKey(month, threshold)),
  );
}

/** `80% of $50.00 spent`, or `$50.00 budget spent` once the whole amount is gone. */
export function budgetAlertText(threshold: number, budgetUSD: number): string {
  return threshold >= BUDGET_EXHAUSTED_PERCENT
    ? `${usd(budgetUSD)} budget spent`
    : `${threshold}% of ${usd(budgetUSD)} spent`;
}

function usd(amount: number): string {
  return amount.toLocaleString(undefined, {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}
