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

<section class="usage-budget" aria-labelledby="usage-budget-title">
  <div class="usage-budget-heading">
    <h2 id="usage-budget-title">Monthly budget</h2>
    <button class="button-secondary" type="button" onclick={startEditing}>
      {budget.amountUSD === null ? "Set budget" : "Edit"}
    </button>
  </div>

  {#if editing}
    <form class="usage-budget-form" onsubmit={save}>
      <label>
        <span>Amount in USD</span>
        <input
          type="number"
          inputmode="decimal"
          min="0"
          max={MAXIMUM_BUDGET_USD}
          step="1"
          placeholder="No budget"
          bind:value={draftAmount}
        />
      </label>
      <label class="usage-budget-toggle">
        <input
          type="checkbox"
          checked={budget.alerts}
          onchange={(event) =>
            onChangeBudget({
              amountUSD: budget.amountUSD,
              alerts: event.currentTarget.checked,
            })}
        />
        <span>Tell me at 80% and 100%</span>
      </label>
      <button class="button-primary" type="submit">Save</button>
      <button class="button-secondary" type="button" onclick={() => (editing = false)}>
        Cancel
      </button>
    </form>
  {:else if progress}
    <div
      class="usage-budget-meter"
      role="progressbar"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={progress.percent}
      aria-valuetext={progress.text}
    >
      <div class="usage-budget-fill" style={`width: ${progress.fraction * 100}%`}></div>
    </div>
    <p class="usage-budget-value" id="usage-budget-value">{progress.text}</p>
  {:else}
    <p class="usage-budget-value">No budget is set for this month.</p>
  {/if}

  {#each pending as threshold (threshold)}
    <p class="usage-budget-alert" role="status">
      <span>{budgetAlertText(threshold, progress?.budgetUSD ?? 0)}</span>
      <button
        class="button-secondary"
        type="button"
        onclick={() => onAcknowledge([...fired, budgetAlertKey(month, threshold)])}
      >
        Got it
      </button>
    </p>
  {/each}
</section>
