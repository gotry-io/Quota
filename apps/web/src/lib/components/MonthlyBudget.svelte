<script lang="ts">
import type { AccountSettingsResponseRead } from "@gotry-io/quota-protocol";
import {
  type AccountError,
  accountNoticeActionLabel,
  accountNoticeRetry,
} from "$lib/account-errors";
import { browserTimezone, usagePeriodResourceKey } from "$lib/account-reads.ts";
import {
  type BudgetEdit,
  fetchAccountSettings,
  saveBudget as saveAccountBudget,
  writeAccountSettings,
} from "$lib/account-settings-client";
import type { AccountStore } from "$lib/account-store.svelte.ts";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import UsageBudgetBar from "$lib/components/UsageBudgetBar.svelte";
import {
  budgetAmountToWire,
  budgetMonth,
  budgetProgress,
  clearLocalBudgetPolicy,
  costDollars,
  NO_BUDGET,
  planBudgetAdoption,
  readFiredBudgetAlerts,
  type UsageBudget,
  usageBudgetFromDocument,
  usageBudgetStorage,
  writeFiredBudgetAlerts,
} from "$lib/usage-budget";
import { usagePeriodRange } from "$lib/usage-period";

/**
 * The monthly budget: the amount and the 80%/100% switch follow the Account, and the meter reads
 * this browser's calendar month from the period read.
 *
 * It is the one reader of the Account settings document on the page, so it hands what it read
 * to `onSettings` for the groups that only show the rest of that document.
 */
let {
  store,
  onSettings,
}: {
  store: AccountStore;
  onSettings?: (settings: AccountSettingsResponseRead) => void;
} = $props();

let budget = $state<UsageBudget>(NO_BUDGET);
let budgetError = $state<AccountError | null>(null);
let firedBudgetAlerts = $state<string[]>(readFiredBudgetAlerts(usageBudgetStorage()));
const timezone = browserTimezone();
const month = $derived(budgetMonth(store.now));
const monthRange = $derived(usagePeriodRange({ segment: "month", offset: 0 }, store.now));
const monthPeriodRead = $derived(
  monthRange
    ? (store.period[usagePeriodResourceKey({ ...monthRange, timezone, breakdown: false })]?.data ??
        null)
    : null,
);
const progress = $derived(
  budget.amountUSD !== null && monthPeriodRead
    ? budgetProgress(
        costDollars(monthPeriodRead.cost),
        budget.amountUSD,
        monthPeriodRead.cost.status !== "complete",
      )
    : null,
);

$effect(() => {
  if (!monthRange) return;
  void store.ensurePeriod(monthRange, { breakdown: false });
});

$effect(() => {
  void loadBudget();
});

function adopt(settings: AccountSettingsResponseRead): void {
  budget = usageBudgetFromDocument(settings.budget);
  onSettings?.(settings);
}

async function loadBudget(): Promise<void> {
  budgetError = null;
  const fetched = await fetchAccountSettings();
  if (fetched.status === "error") {
    budgetError = fetched.error;
    return;
  }
  const storage = usageBudgetStorage();
  const plan = planBudgetAdoption(fetched.settings, storage);
  if (plan.write) {
    const written = await writeAccountSettings(plan.write);
    if (written.status === "error") {
      budgetError = written.error;
      return;
    }
    adopt(written.settings);
  } else {
    budget = usageBudgetFromDocument(plan.local.budget);
    onSettings?.(fetched.settings);
  }
  clearLocalBudgetPolicy(storage);
}

function changeBudget(next: UsageBudget): void {
  const edit: BudgetEdit =
    next.alerts !== budget.alerts
      ? { kind: "set_budget_alerts", value: next.alerts }
      : { kind: "set_budget_amount", value: budgetAmountToWire(next.amountUSD) };
  budget = next;
  void persistBudget(edit);
}

async function persistBudget(edit: BudgetEdit): Promise<void> {
  budgetError = null;
  const result = await saveAccountBudget(edit);
  if (result.status === "ok") {
    adopt(result.settings);
    return;
  }
  if (result.status === "conflict") {
    adopt(result.settings);
    budgetError = { status: "unavailable", message: result.message, action: { type: "retry" } };
    return;
  }
  if (result.status === "error") {
    budgetError = result.error;
  }
}

function acknowledgeBudgetAlerts(keys: readonly string[]): void {
  firedBudgetAlerts = [...keys];
  writeFiredBudgetAlerts(usageBudgetStorage(), firedBudgetAlerts);
}
</script>

{#if budgetError}
  <RetryNotice
    message={budgetError.message}
    actionLabel={accountNoticeActionLabel(budgetError)}
    onRetry={accountNoticeRetry(budgetError, () => void loadBudget())}
  />
{/if}
<UsageBudgetBar
  {budget}
  {progress}
  {month}
  fired={firedBudgetAlerts}
  onChangeBudget={changeBudget}
  onAcknowledge={acknowledgeBudgetAlerts}
/>
