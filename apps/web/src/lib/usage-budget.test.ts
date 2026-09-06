import { expect, it } from "vitest";
import {
  budgetAlertKey,
  budgetAlertText,
  budgetMonth,
  budgetProgress,
  normalizedBudgetAmount,
  pendingBudgetAlerts,
  readBudget,
  readFiredBudgetAlerts,
  writeBudget,
  writeFiredBudgetAlerts,
} from "./usage-budget.ts";

function memoryStorage(): Storage {
  const values = new Map<string, string>();
  return {
    get length() {
      return values.size;
    },
    clear: () => values.clear(),
    getItem: (key: string) => values.get(key) ?? null,
    key: (index: number) => [...values.keys()][index] ?? null,
    removeItem: (key: string) => void values.delete(key),
    setItem: (key: string, value: string) => void values.set(key, value),
  };
}

it("keeps an amount and an alert switch, and forgets an amount that is not a budget", () => {
  const storage = memoryStorage();
  expect(readBudget(storage)).toEqual({ amountUSD: null, alerts: true });

  writeBudget(storage, { amountUSD: 50, alerts: false });
  expect(readBudget(storage)).toEqual({ amountUSD: 50, alerts: false });

  writeBudget(storage, { amountUSD: 0, alerts: true });
  expect(readBudget(storage)).toEqual({ amountUSD: null, alerts: true });

  expect(normalizedBudgetAmount(-1)).toBeNull();
  expect(normalizedBudgetAmount(2_000_000)).toBeNull();
  expect(normalizedBudgetAmount(12.345)).toBe(12.35);
});

it("reads no budget at all when there is no storage to read", () => {
  expect(readBudget(null)).toEqual({ amountUSD: null, alerts: true });
  expect(readFiredBudgetAlerts(null)).toEqual([]);
});

it("writes the progress line the three clients share", () => {
  const progress = budgetProgress(5.39, 50, false);
  expect(progress.percent).toBe(10);
  expect(progress.text).toBe("$5.39 / $50.00 · 10%");
  expect(budgetProgress(5.39, 50, true).text.startsWith("≥ ")).toBe(true);
  expect(budgetProgress(75, 50, false).fraction).toBe(1);
  expect(budgetProgress(49.999, 50, false).percent).toBe(99);
});

it("announces 80% and 100% once each per month", () => {
  const budget = { amountUSD: 50, alerts: true };
  const month = budgetMonth(new Date(2026, 8, 6));
  expect(month).toBe("2026-09");

  expect(pendingBudgetAlerts(budget, budgetProgress(20, 50, false), month, [])).toEqual([]);
  expect(pendingBudgetAlerts(budget, budgetProgress(40, 50, false), month, [])).toEqual([80]);
  expect(pendingBudgetAlerts(budget, budgetProgress(60, 50, false), month, [])).toEqual([80, 100]);

  const fired = [budgetAlertKey(month, 80), budgetAlertKey(month, 100)];
  expect(pendingBudgetAlerts(budget, budgetProgress(60, 50, false), month, fired)).toEqual([]);
  expect(pendingBudgetAlerts(budget, budgetProgress(60, 50, false), "2026-10", fired)).toEqual([
    80, 100,
  ]);
  expect(
    pendingBudgetAlerts({ amountUSD: 50, alerts: false }, budgetProgress(60, 50, false), month, []),
  ).toEqual([]);
});

it("remembers which crossings were already announced", () => {
  const storage = memoryStorage();
  writeFiredBudgetAlerts(storage, ["budget:2026-09:80"]);
  expect(readFiredBudgetAlerts(storage)).toEqual(["budget:2026-09:80"]);
  storage.setItem("quota.usage.budget.fired", "not json");
  expect(readFiredBudgetAlerts(storage)).toEqual([]);
});

it("writes what a crossing says", () => {
  expect(budgetAlertText(80, 50)).toBe("80% of $50.00 spent");
  expect(budgetAlertText(100, 50)).toBe("$50.00 budget spent");
});
