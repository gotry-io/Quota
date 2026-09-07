<script lang="ts">
import { foldUsageActivityDays } from "@gotry-io/quota-model";
import type { UsagePeriodRead } from "@gotry-io/quota-protocol";
import { goto } from "$app/navigation";
import { page } from "$app/state";
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import { usageStatusLine } from "$lib/account-overview";
import { accountActivityRange } from "$lib/account-reads.ts";
import { activityRangeKey, getAccountStore } from "$lib/account-store.svelte.ts";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import UsageActivity from "$lib/components/UsageActivity.svelte";
import UsageBreakdown from "$lib/components/UsageBreakdown.svelte";
import UsageBudgetBar from "$lib/components/UsageBudgetBar.svelte";
import UsageDaily from "$lib/components/UsageDaily.svelte";
import UsagePeriodBar from "$lib/components/UsagePeriodBar.svelte";
import { costBasisLabel, formatCost, formatCount, formatUtcDateRange } from "$lib/format";
import { usageActivityDayFromQuery, usageActivityDayHref } from "$lib/usage-activity";
import {
  cacheHitLabel,
  cacheSavedLabel,
  costPricedLabel,
  usageDailyRows,
} from "$lib/usage-metrics";
import {
  budgetMonth,
  budgetProgress,
  costDollars,
  readBudget,
  readFiredBudgetAlerts,
  type UsageBudget,
  usageBudgetStorage,
  writeBudget,
  writeFiredBudgetAlerts,
} from "$lib/usage-budget";
import {
  type UsagePeriodSelection,
  usagePeriodFromUrl,
  usagePeriodHref,
  usagePeriodName,
  usagePeriodRange,
  usagePeriodSummaryKey,
  usagePeriodTitle,
} from "$lib/usage-period";

const store = getAccountStore();
let budget = $state<UsageBudget>(readBudget(usageBudgetStorage()));
let firedBudgetAlerts = $state<string[]>(readFiredBudgetAlerts(usageBudgetStorage()));
const utcDate = $derived(store.now.toISOString().slice(0, 10));
const activityRange = $derived(accountActivityRange(new Date(`${utcDate}T00:00:00Z`)));
const rangeKey = $derived(activityRangeKey(activityRange));
const selection = $derived(usagePeriodFromUrl(page.url));
const selectedDay = $derived(
  usageActivityDayFromQuery(page.url.searchParams.get("day"), activityRange),
);
const activityEntry = $derived(store.activity[rangeKey]);
const activityDays = $derived(activityEntry?.data ?? null);
const activityError = $derived(activityEntry?.status === "error" ? activityEntry.error : null);
const summaryKey = $derived(usagePeriodSummaryKey(selection));
const selectedRange = $derived(usagePeriodRange(selection, store.now));
/**
 * The summary answers the four periods it folds; every other one is folded here from the
 * activity days this page already holds, which is why it has no model breakdown.
 */
const period = $derived<UsagePeriodRead | null>(
  summaryKey && store.summary
    ? store.summary.usage[summaryKey]
    : activityDays && selectedRange
      ? foldUsageActivityDays(activityDays, selectedRange)
      : null,
);
const folded = $derived(summaryKey === null);
const status = $derived(
  period ? usageStatusLine(usagePeriodName(selection), period.partial) : null,
);
const month = $derived(budgetMonth(store.now));
const monthRange = $derived(usagePeriodRange({ segment: "month", offset: 0 }, store.now));
const monthPeriod = $derived(
  activityDays && monthRange ? foldUsageActivityDays(activityDays, monthRange) : null,
);
const budgetView = $derived(
  budget.amountUSD !== null && monthPeriod
    ? budgetProgress(
        costDollars(monthPeriod.cost),
        budget.amountUSD,
        monthPeriod.cost.status !== "complete",
      )
    : null,
);
const detailEntry = $derived(selectedDay ? store.dayDetail[selectedDay] : undefined);
const dayDetail = $derived(detailEntry?.data ?? null);
const dayError = $derived(detailEntry?.error ?? null);
/** The table covers the period's own days, bounded by the activity days the page holds. */
const dailyRange = $derived(
  selectedRange
    ? {
        from: selectedRange.from < activityRange.from ? activityRange.from : selectedRange.from,
        to: selectedRange.to > activityRange.to ? activityRange.to : selectedRange.to,
      }
    : null,
);
const dailyRows = $derived(activityDays ? usageDailyRows(activityDays, dailyRange) : []);
const cacheHit = $derived(period ? cacheHitLabel(period.totals) : null);
const cacheSaved = $derived(period ? cacheSavedLabel(period.cache_saved) : null);
const priced = $derived(period ? costPricedLabel(period.cost) : null);
const detailLoading = $derived(
  selectedDay !== null &&
    (detailEntry === undefined ||
      detailEntry.status === "idle" ||
      detailEntry.status === "loading"),
);

$effect(() => {
  void store.ensureActivity(activityRange);
});

$effect(() => {
  const date = selectedDay;
  if (!date) return;
  void store.ensureDay(date);
});

function selectPeriod(next: UsagePeriodSelection): void {
  void goto(usagePeriodHref(page.url, next), {
    replaceState: true,
    keepFocus: true,
    noScroll: true,
  });
}

function writeDay(day: string | null): void {
  void goto(usageActivityDayHref(page.url, day), {
    replaceState: true,
    keepFocus: true,
    noScroll: true,
  });
}

function saveBudget(next: UsageBudget): void {
  budget = writeBudget(usageBudgetStorage(), next);
}

function acknowledgeBudgetAlerts(keys: readonly string[]): void {
  firedBudgetAlerts = [...keys];
  writeFiredBudgetAlerts(usageBudgetStorage(), firedBudgetAlerts);
}
</script>

<svelte:head>
  <title>Usage · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

<header class="usage-heading">
  <div>
    <h1 id="dashboard-title">Usage</h1>
    {#if status}
      <p class="dashboard-status">{status}</p>
    {/if}
  </div>
  <UsagePeriodBar
    {selection}
    today={store.now}
    earliest={activityRange.from}
    onSelect={selectPeriod}
  />
</header>

<UsageBudgetBar
  {budget}
  progress={budgetView}
  {month}
  fired={firedBudgetAlerts}
  onChangeBudget={saveBudget}
  onAcknowledge={acknowledgeBudgetAlerts}
/>

{#if store.loadError}
  <RetryNotice
    message={store.loadError.message}
    actionLabel={accountNoticeActionLabel(store.loadError)}
    onRetry={accountNoticeRetry(store.loadError, () => void store.refresh())}
  />
{/if}

{#if !store.summary}
  {#if !store.loadError}
    <LoadingBlock lines={4} label="Loading Usage totals" />
  {/if}
{:else if period}
  <p class="usage-period-range" id="usage-period-range">
    {usagePeriodTitle(selection, store.now)}
  </p>
  <div class="usage-totals">
    <article>
      <span>Tokens</span>
      <strong id="token-total">{formatCount(period.totals.total_tokens)}</strong>
      <small id="token-split"
        >{`${formatCount(period.totals.input_tokens)} in · ${formatCount(period.totals.output_tokens)} out`}</small
      >
    </article>
    <article>
      <span>API-equivalent cost</span>
      <strong id="cost-total">{formatCost(period.cost)}</strong>
      <small id="cost-basis">{costBasisLabel(period.cost)}</small>
    </article>
    <article>
      <span>Messages</span>
      <strong id="message-total">{formatCount(period.totals.messages)}</strong>
    </article>
    <article>
      <span>Cache hit</span>
      <strong id="cache-hit">{cacheHit ?? "—"}</strong>
      <small id="cache-saved">{cacheSaved ?? "Nothing priced to compare"}</small>
    </article>
    <article>
      <span>Reasoning</span>
      <strong id="reasoning-total">{formatCount(period.totals.reasoning_tokens)}</strong>
      <small>tokens of output</small>
    </article>
    {#if priced}
      <p class="usage-priced" id="cost-priced">{priced}</p>
    {/if}
  </div>

  {#if dailyRows.length > 0}
    <section class="usage-daily-panel" aria-labelledby="usage-daily-title">
      <div class="usage-panel-heading">
        <h2 id="usage-daily-title">Daily</h2>
      </div>
      <UsageDaily rows={dailyRows} />
    </section>
  {/if}

  <div class="usage-columns">
    <section class="usage-tree-panel" aria-labelledby="usage-tree-title">
      <h2 id="usage-tree-title" class="visually-hidden">By model</h2>
      {#if folded}
        <p class="usage-day-note" id="usage-breakdown-note">
          A range this page folded itself carries totals only. The model breakdown is on Today,
          Last 7 days, Last 30 days, and All.
        </p>
      {:else}
        <UsageBreakdown {period} />
      {/if}
    </section>
    <section class="usage-activity-panel" aria-labelledby="usage-activity-title">
      <div class="usage-panel-heading">
        <h2 id="usage-activity-title">Activity</h2>
        <span id="usage-activity-status" class="count-pill" aria-live="polite">
          {formatUtcDateRange(activityRange.from, activityRange.to)}
        </span>
      </div>
      {#if activityDays}
        {#if activityError}
          <RetryNotice
            message={activityError.message}
            actionLabel={accountNoticeActionLabel(activityError)}
            onRetry={accountNoticeRetry(activityError, () =>
              void store.ensureActivity(activityRange, { maxAgeMs: 0 }),
            )}
          />
        {/if}
        <UsageActivity
          days={activityDays}
          range={activityRange}
          selectedDate={selectedDay}
          detail={dayDetail}
          detailError={dayError}
          detailLoading={detailLoading}
          onSelectDate={(date) => writeDay(date)}
          onClose={() => writeDay(null)}
          onRetryDetail={() => {
            if (selectedDay) void store.ensureDay(selectedDay, { maxAgeMs: 0 });
          }}
        />
      {:else if activityError}
        <div id="usage-activity-grid" class="usage-activity-state" aria-live="polite">
          <RetryNotice
            message={activityError.message}
            actionLabel={accountNoticeActionLabel(activityError)}
            onRetry={accountNoticeRetry(activityError, () =>
              void store.ensureActivity(activityRange, { maxAgeMs: 0 }),
            )}
          />
        </div>
      {:else}
        <div id="usage-activity-grid" class="usage-activity-state" aria-live="polite">
          <LoadingBlock lines={4} label="Loading Usage activity" />
        </div>
      {/if}
    </section>
  </div>
{/if}
