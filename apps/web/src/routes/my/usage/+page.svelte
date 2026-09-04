<script lang="ts">
import type { UsageActivityDayRead, UsagePeriodRead } from "@gotry-io/quota-protocol";
import { agentDisplayName, inferenceProviderDisplayName } from "@gotry-io/quota-protocol";
import { type AccountError, accountActivityRange, fetchAccountActivity } from "$lib/account-client";
import { getAccountDashboard } from "$lib/account-dashboard.svelte.ts";
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import UsageActivity from "$lib/components/UsageActivity.svelte";
import { costBasisLabel, formatCost, formatCount } from "$lib/format";

const periodNames = [
  { key: "today", label: "Today" },
  { key: "last_7_days", label: "Last 7 days" },
  { key: "last_30_days", label: "Last 30 days" },
  { key: "all", label: "All time" },
] as const;

const dashboard = getAccountDashboard();
let activityDays = $state<UsageActivityDayRead[] | null>(null);
let activityError = $state<AccountError | null>(null);
let selectedPeriod = $state<(typeof periodNames)[number]["key"]>("last_30_days");

const activityRange = accountActivityRange(new Date());
let period = $derived<UsagePeriodRead | null>(
  dashboard.summary ? dashboard.summary.usage[selectedPeriod] : null,
);
/** Every model leaf of the selected period, flattened for one table. */
let modelRows = $derived(
  (period?.agents ?? []).flatMap((agent) =>
    agent.providers.flatMap((provider) =>
      provider.models.map((model) => ({
        key: `${agent.agent}/${provider.provider}/${model.model}`,
        agent: agent.agent,
        provider: provider.provider,
        ...model,
      })),
    ),
  ),
);

$effect(() => {
  void loadActivity();
});

async function loadActivity(): Promise<void> {
  const result = await fetchAccountActivity(activityRange);
  if (result.status === "ok") {
    activityDays = result.activity.days;
    activityError = null;
    return;
  }
  activityError = result;
}
</script>

<svelte:head>
  <title>Usage · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

<section class="dashboard-section" aria-labelledby="usage-title">
  <div class="dashboard-section-heading">
    <div>
      <p class="eyebrow">Usage</p>
      <h2 id="usage-title">Totals</h2>
    </div>
    <div class="period-tabs" role="group" aria-label="Usage period">
      {#each periodNames as item (item.key)}
        <button
          class="text-button"
          type="button"
          aria-pressed={selectedPeriod === item.key}
          onclick={() => {
            selectedPeriod = item.key;
          }}>{item.label}</button
        >
      {/each}
    </div>
  </div>
  {#if dashboard.loadError}
    <RetryNotice
      message={dashboard.loadError.message}
      actionLabel={accountNoticeActionLabel(dashboard.loadError)}
      onRetry={accountNoticeRetry(dashboard.loadError, () => void dashboard.loadSummary())}
    />
  {/if}
  {#if !dashboard.summary}
    {#if !dashboard.loadError}
      <LoadingBlock lines={4} label="Loading Usage totals" />
    {/if}
  {:else}
    <div class="summary-grid">
      <article
        ><span>Tokens</span><strong id="token-total"
          >{period ? formatCount(period.totals.total_tokens) : "—"}</strong
        ><small id="token-split"
          >{period
            ? `${formatCount(period.totals.input_tokens)} in · ${formatCount(period.totals.output_tokens)} out`
            : ""}</small
        ></article
      >
      <article
        ><span>API-equivalent cost</span><strong id="cost-total"
          >{period ? formatCost(period.cost) : "—"}</strong
        >{#if period}<small id="cost-basis">{costBasisLabel(period.cost)}</small>{/if}</article
      >
    </div>
    {#if period?.partial}
      <p class="usage-day-note">Some hours in this period were scanned incompletely.</p>
    {/if}
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th scope="col">Agent</th>
            <th scope="col">Provider</th>
            <th scope="col">Model</th>
            <th scope="col">Input</th>
            <th scope="col">Output</th>
            <th scope="col">Cost</th>
          </tr>
        </thead>
        <tbody id="usage-breakdown">
          {#if period}
            {#if modelRows.length === 0}
              <tr><td colspan="6">No Usage has been synced for this period.</td></tr>
            {:else}
              {#each modelRows as row (row.key)}
                <tr>
                  <td>{agentDisplayName(row.agent)}</td>
                  <td>{inferenceProviderDisplayName(row.provider)}</td>
                  <td>{row.model}</td>
                  <td>{formatCount(row.totals.input_tokens)}</td>
                  <td>{formatCount(row.totals.output_tokens)}</td>
                  <td>{formatCost(row.cost)}</td>
                </tr>
              {/each}
            {/if}
          {/if}
        </tbody>
      </table>
    </div>
  {/if}
</section>

<section class="dashboard-section" aria-labelledby="usage-activity-title">
  <div class="dashboard-section-heading">
    <div>
      <p class="eyebrow">Usage</p>
      <h2 id="usage-activity-title">Activity</h2>
    </div>
    <span id="usage-activity-status" class="count-pill" aria-live="polite">
      {activityRange.from} – {activityRange.to}
    </span>
  </div>
  {#if activityDays}
    <UsageActivity days={activityDays} range={activityRange} />
  {:else if activityError}
    <div id="usage-activity-grid" class="usage-activity-state" aria-live="polite">
      <RetryNotice
        message={activityError.message}
        actionLabel={accountNoticeActionLabel(activityError)}
        onRetry={accountNoticeRetry(activityError, () => void loadActivity())}
      />
    </div>
  {:else}
    <div id="usage-activity-grid" class="usage-activity-state" aria-live="polite">
      <LoadingBlock lines={4} label="Loading Usage activity" />
    </div>
  {/if}
</section>
