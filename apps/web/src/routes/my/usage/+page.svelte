<script lang="ts">
import type { UsagePeriodRead } from "@gotry-io/quota-protocol";
import { goto } from "$app/navigation";
import { page } from "$app/state";
import {
  type AccountError,
  accountNoticeActionLabel,
  accountNoticeRetry,
} from "$lib/account-errors";
import { usageStatusLine } from "$lib/account-overview";
import {
  accountActivityRange,
  accountUsagePeriodTruncated,
  accountUsagePeriodView,
  browserTimezone,
  usagePeriodResourceKey,
} from "$lib/account-reads.ts";
import {
  type BudgetEdit,
  fetchAccountSettings,
  saveBudget as saveAccountBudget,
  writeAccountSettings,
} from "$lib/account-settings-client";
import { activityRangeKey, getAccountStore } from "$lib/account-store.svelte.ts";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import UsageActivity from "$lib/components/UsageActivity.svelte";
import UsageBreakdown from "$lib/components/UsageBreakdown.svelte";
import UsageBudgetBar from "$lib/components/UsageBudgetBar.svelte";
import UsageDaily from "$lib/components/UsageDaily.svelte";
import UsageExportMenu from "$lib/components/UsageExportMenu.svelte";
import UsagePeriodBar from "$lib/components/UsagePeriodBar.svelte";
import UsageRhythm from "$lib/components/UsageRhythm.svelte";
import { costBasisLabel, formatCost, formatCount, formatUtcDateRange } from "$lib/format";
import { usageActivityDayFromQuery, usageActivityDayHref } from "$lib/usage-activity";
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
import {
  accountPeriodExportInput,
  type UsageExportInput,
  WEB_APP_VERSION,
} from "$lib/usage-export";
import {
  cacheHitLabel,
  cacheSavedLabel,
  costPricedLabel,
  usageDailyRows,
} from "$lib/usage-metrics";
import {
  type UsagePeriodSelection,
  usagePeriodFromUrl,
  usagePeriodHref,
  usagePeriodName,
  usagePeriodRange,
  usagePeriodReadsFromSummary,
  usagePeriodTitle,
} from "$lib/usage-period";

const store = getAccountStore();
let budget = $state<UsageBudget>(NO_BUDGET);
let budgetError = $state<AccountError | null>(null);
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
const fromSummary = $derived(usagePeriodReadsFromSummary(selection));
const selectedRange = $derived(usagePeriodRange(selection, store.now));
const timezone = $derived(browserTimezone());
const selectedPeriodKey = $derived(
  selectedRange ? usagePeriodResourceKey({ ...selectedRange, timezone, breakdown: true }) : null,
);
const selectedPeriodEntry = $derived(
  selectedPeriodKey ? store.period[selectedPeriodKey] : undefined,
);
const selectedPeriodRead = $derived(selectedPeriodEntry?.data ?? null);
/**
 * `all` is the summary's 730 UTC-day window. Every other selection is the period read for those
 * local dates, including the presets the summary also folds.
 */
const period = $derived<UsagePeriodRead | null>(
  fromSummary && store.summary
    ? store.summary.usage.all
    : selectedPeriodRead
      ? accountUsagePeriodView(selectedPeriodRead)
      : null,
);
const truncated = $derived(
  selectedPeriodRead ? accountUsagePeriodTruncated(selectedPeriodRead) : false,
);
const periodError = $derived(
  !fromSummary && selectedPeriodEntry?.status === "error" ? selectedPeriodEntry.error : null,
);
const status = $derived(
  period ? usageStatusLine(usagePeriodName(selection), period.partial, truncated) : null,
);
const month = $derived(budgetMonth(store.now));
const monthRange = $derived(usagePeriodRange({ segment: "month", offset: 0 }, store.now));
const monthPeriodRead = $derived.by(() => {
  if (!monthRange) return null;
  const withoutBreakdown =
    store.period[usagePeriodResourceKey({ ...monthRange, timezone, breakdown: false })]?.data ??
    null;
  const withBreakdown =
    store.period[usagePeriodResourceKey({ ...monthRange, timezone, breakdown: true })]?.data ??
    null;
  return withoutBreakdown ?? withBreakdown;
});
const budgetView = $derived(
  budget.amountUSD !== null && monthPeriodRead
    ? budgetProgress(
        costDollars(monthPeriodRead.cost),
        budget.amountUSD,
        monthPeriodRead.cost.status !== "complete",
      )
    : null,
);
const detailEntry = $derived(selectedDay ? store.dayDetail[selectedDay] : undefined);
const dayDetail = $derived(detailEntry?.data ?? null);
const dayError = $derived(detailEntry?.error ?? null);
const dailyRows = $derived(
  fromSummary || !selectedPeriodRead
    ? []
    : usageDailyRows(selectedPeriodRead.days, {
        from: selectedPeriodRead.request.from,
        to: selectedPeriodRead.request.to,
      }),
);
const rhythmKey = $derived(selectedRange ? activityRangeKey(selectedRange) : null);
const rhythmEntry = $derived(rhythmKey ? store.rhythm[rhythmKey] : undefined);
const rhythm = $derived(rhythmEntry?.data ?? null);
const cacheHit = $derived(period ? cacheHitLabel(period.totals) : null);
const cacheSaved = $derived(period ? cacheSavedLabel(period.cache_saved) : null);
const priced = $derived(period ? costPricedLabel(period.cost) : null);
const detailLoading = $derived(
  selectedDay !== null &&
    (detailEntry === undefined ||
      detailEntry.status === "idle" ||
      detailEntry.status === "loading"),
);
const exportInput = $derived.by((): UsageExportInput | null => {
  if (fromSummary || !selectedPeriodRead) return null;
  return accountPeriodExportInput(selectedPeriodRead, {
    exportedAt: store.now.toISOString(),
    appVersion: WEB_APP_VERSION,
  });
});

$effect(() => {
  void store.ensureActivity(activityRange);
});

$effect(() => {
  if (fromSummary || !selectedRange) return;
  void store.ensurePeriod(selectedRange, { breakdown: true });
});

$effect(() => {
  if (!monthRange) return;
  const sameAsSelected =
    selectedRange !== null &&
    !fromSummary &&
    selectedRange.from === monthRange.from &&
    selectedRange.to === monthRange.to;
  if (sameAsSelected) return;
  void store.ensurePeriod(monthRange, { breakdown: false });
});

$effect(() => {
  if (selection.segment === "all" || !selectedRange) return;
  void store.ensureRhythm(selectedRange);
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

$effect(() => {
  void loadBudget();
});

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
    if (written.status === "ok" || written.status === "stale" || written.status === "conflict") {
      budget = usageBudgetFromDocument(written.settings.budget);
    }
  } else {
    budget = usageBudgetFromDocument(plan.local.budget);
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
    budget = usageBudgetFromDocument(result.settings.budget);
    return;
  }
  if (result.status === "conflict") {
    budget = usageBudgetFromDocument(result.settings.budget);
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
  <div class="usage-heading-tools">
    <UsageExportMenu input={exportInput} />
    <UsagePeriodBar
      {selection}
      today={store.now}
      earliest={activityRange.from}
      onSelect={selectPeriod}
    />
  </div>
</header>

<UsageBudgetBar
  {budget}
  progress={budgetView}
  {month}
  fired={firedBudgetAlerts}
  onChangeBudget={changeBudget}
  onAcknowledge={acknowledgeBudgetAlerts}
/>

{#if budgetError}
  <RetryNotice
    message={budgetError.message}
    actionLabel={accountNoticeActionLabel(budgetError)}
    onRetry={accountNoticeRetry(budgetError, () => void loadBudget())}
  />
{/if}

{#if store.loadError}
  <RetryNotice
    message={store.loadError.message}
    actionLabel={accountNoticeActionLabel(store.loadError)}
    onRetry={accountNoticeRetry(store.loadError, () => void store.refresh())}
  />
{/if}

{#if periodError && !period}
  <RetryNotice
    message={periodError.message}
    actionLabel={accountNoticeActionLabel(periodError)}
    onRetry={accountNoticeRetry(periodError, () =>
      selectedRange
        ? void store.ensurePeriod(selectedRange, { breakdown: true, maxAgeMs: 0 })
        : undefined,
    )}
  />
{/if}

{#if !store.summary}
  {#if !store.loadError}
    <LoadingBlock lines={4} label="Loading Usage totals" />
  {/if}
{:else if !period}
  {#if !periodError}
    <LoadingBlock lines={4} label="Loading Usage totals" />
  {/if}
{:else}
  <p class="usage-period-range" id="usage-period-range">
    {usagePeriodTitle(selection, store.now)}
  </p>
  {#if truncated}
    <p class="usage-day-note" id="usage-retention-note">
      This range goes past what Quota still keeps.
    </p>
  {/if}
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

  {#if selection.segment !== "all" && rhythm}
    <section class="usage-daily-panel" aria-labelledby="usage-rhythm-title">
      <div class="usage-panel-heading">
        <h2 id="usage-rhythm-title">Rhythm</h2>
      </div>
      <UsageRhythm hoursOfDay={rhythm.hours_of_day} weekdayHours={rhythm.weekday_hours} />
    </section>
  {/if}

  <div class="usage-columns">
    <section class="usage-tree-panel" aria-labelledby="usage-tree-title">
      <h2 id="usage-tree-title" class="visually-hidden">By model</h2>
      <UsageBreakdown {period} />
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
