<script lang="ts">
import {
  budgetAlertKey,
  budgetAlertText,
  MAXIMUM_BUDGET_USD,
  normalizedBudgetAmount,
  pendingBudgetAlerts,
  type UsageBudget,
  type UsageBudgetProgress,
} from "$lib/usage-budget";

let {
  budget,
  progress,
  month,
  fired,
  onChangeBudget,
  onAcknowledge,
}: {
  budget: UsageBudget;
  /** Null when no budget is set, or when this month's cost is not known yet. */
  progress: UsageBudgetProgress | null;
  month: string;
  fired: readonly string[];
  onChangeBudget: (budget: UsageBudget) => void;
  onAcknowledge: (keys: readonly string[]) => void;
} = $props();

let editing = $state(false);
/** A number input binds a number, and an empty field binds nothing at all. */
let draftAmount = $state<number | undefined>(undefined);

const pending = $derived(pendingBudgetAlerts(budget, progress, month, fired));
const amountText = $derived(
  budget.amountUSD === null ? "No budget" : `$${budget.amountUSD.toFixed(2)}`,
);

function startEditing(): void {
  draftAmount = budget.amountUSD ?? undefined;
  editing = true;
}

function save(event: SubmitEvent): void {
  event.preventDefault();
  onChangeBudget({
    amountUSD: normalizedBudgetAmount(draftAmount ?? null),
    alerts: budget.alerts,
  });
  editing = false;
}
</script>

<div class="split-row">
  {#if editing}
    <form class="budget-form" onsubmit={save}>
      <label class="visually-hidden" for="budget-amount">Amount in USD</label>
      <span class="field">
        <span aria-hidden="true">$</span>
        <input
          id="budget-amount"
          type="number"
          inputmode="decimal"
          min="0"
          max={MAXIMUM_BUDGET_USD}
          step="1"
          placeholder="No budget"
          bind:value={draftAmount}
        />
      </span>
      <button class="pill primary" type="submit">Save</button>
      <button class="pill" type="button" onclick={() => (editing = false)}>Cancel</button>
    </form>
  {:else}
    <div>
      <div class="split-row-title">Amount</div>
      <div class="split-row-detail">{amountText}</div>
    </div>
    <button class="pill" type="button" onclick={startEditing}>
      {budget.amountUSD === null ? "Set budget" : "Edit"}
    </button>
  {/if}
</div>
<label class="split-row">
  <span class="split-row-title">Tell me at 80% and 100%</span>
  <input
    class="switch"
    type="checkbox"
    role="switch"
    checked={budget.alerts}
    onchange={(event) =>
      onChangeBudget({
        amountUSD: budget.amountUSD,
        alerts: event.currentTarget.checked,
      })}
  />
</label>
<div class="split-row">
  <div>
    <div class="split-row-title">This month</div>
    {#if progress}
      <div class="split-row-detail" id="usage-budget-value">{progress.text}</div>
    {:else}
      <div class="split-row-detail">No budget is set for this month.</div>
    {/if}
  </div>
  {#if progress}
    <div
      class="budget-meter"
      class:budget-meter-warn={progress.percent >= 80 && progress.percent < 100}
      class:budget-meter-critical={progress.percent >= 100}
      role="progressbar"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={progress.percent}
      aria-valuetext={progress.text}
    >
      <i style={`width: ${progress.fraction * 100}%`}></i>
    </div>
  {/if}
</div>

{#each pending as threshold (threshold)}
  <p class="notice budget-alert" role="status">
    <span>{budgetAlertText(threshold, progress?.budgetUSD ?? 0)}</span>
    <button
      class="pill sm"
      type="button"
      onclick={() => onAcknowledge([...fired, budgetAlertKey(month, threshold)])}
    >
      Got it
    </button>
  </p>
{/each}

<style>
.budget-form {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  align-items: center;
}

.budget-form input {
  width: 110px;
}

.budget-meter {
  width: min(200px, 40vw);
  height: 6px;
  overflow: hidden;
  border-radius: 9999px;
  background: var(--meter-track);
}

.budget-meter i {
  display: block;
  height: 100%;
  border-radius: 9999px;
  background: var(--quota-healthy);
}

.budget-meter-warn i {
  background: var(--quota-warning);
}

.budget-meter-critical i {
  background: var(--quota-critical);
}

.budget-alert {
  margin-top: 12px;
}
</style>
