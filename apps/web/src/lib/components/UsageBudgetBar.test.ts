import { cleanup, fireEvent, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it, vi } from "vitest";
import { budgetAlertKey, budgetProgress, type UsageBudget } from "$lib/usage-budget";
import UsageBudgetBar from "./UsageBudgetBar.svelte";

afterEach(cleanup);

const month = "2026-09";

function mount(budget: UsageBudget, percentOf: number | null, fired: string[] = []) {
  const onChangeBudget = vi.fn();
  const onAcknowledge = vi.fn();
  const progress =
    percentOf === null || budget.amountUSD === null
      ? null
      : budgetProgress(percentOf, budget.amountUSD, false);
  const view = render(UsageBudgetBar, {
    budget,
    progress,
    month,
    fired,
    onChangeBudget,
    onAcknowledge,
  });
  return { onChangeBudget, onAcknowledge, view };
}

it("meters this month against the budget and says when there is none", () => {
  mount({ amountUSD: 50, alerts: true }, 5.39);
  const meter = screen.getByRole("progressbar");
  expect(meter.getAttribute("aria-valuenow")).toBe("10");
  expect(screen.getByText("$5.39 / $50.00 · 10%")).toBeTruthy();

  cleanup();
  mount({ amountUSD: null, alerts: true }, null);
  expect(screen.getByText("No budget is set for this month.")).toBeTruthy();
  expect(screen.queryByRole("progressbar")).toBeNull();
});

it("saves an amount and the alert switch separately", async () => {
  const { onChangeBudget } = mount({ amountUSD: 50, alerts: true }, 5.39);

  fireEvent.click(screen.getByRole("button", { name: "Edit" }));
  const amount = screen.getByLabelText("Amount in USD") as HTMLInputElement;
  expect(amount.value).toBe("50");

  fireEvent.click(screen.getByLabelText("Tell me at 80% and 100%"));
  expect(onChangeBudget).toHaveBeenCalledWith({ amountUSD: 50, alerts: false });

  await fireEvent.input(amount, { target: { value: "120" } });
  await fireEvent.click(screen.getByRole("button", { name: "Save" }));
  expect(onChangeBudget).toHaveBeenLastCalledWith({ amountUSD: 120, alerts: true });
});

it("announces each crossing once and records the one acknowledged", async () => {
  const { onAcknowledge } = mount({ amountUSD: 50, alerts: true }, 45);
  expect(screen.getByText("80% of $50.00 spent")).toBeTruthy();
  expect(screen.queryByText("$50.00 budget spent")).toBeNull();

  await fireEvent.click(screen.getByRole("button", { name: "Got it" }));
  expect(onAcknowledge).toHaveBeenCalledWith([budgetAlertKey(month, 80)]);

  // A month already told about its 80% is not told again.
  cleanup();
  mount({ amountUSD: 50, alerts: true }, 45, [budgetAlertKey(month, 80)]);
  expect(screen.queryByText("80% of $50.00 spent")).toBeNull();

  // Alerts switched off say nothing at all, however far past the budget the month is.
  cleanup();
  mount({ amountUSD: 50, alerts: false }, 70);
  expect(screen.queryByText("80% of $50.00 spent")).toBeNull();
  expect(screen.queryByText("$50.00 budget spent")).toBeNull();
});
