<script lang="ts">
import type { UsageActivityDayRead, UsagePeriodRead } from "@gotry-io/quota-protocol";
import { goto } from "$app/navigation";
import { page } from "$app/state";
import { type AccountError, accountActivityRange, fetchAccountActivity } from "$lib/account-client";
import { getAccountDashboard } from "$lib/account-dashboard.svelte.ts";
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import UsageActivity from "$lib/components/UsageActivity.svelte";
import UsageBreakdown from "$lib/components/UsageBreakdown.svelte";
import UsagePeriodTabs from "$lib/components/UsagePeriodTabs.svelte";
import { costBasisLabel, formatCost, formatCount } from "$lib/format";
import { usageActivityDayFromQuery, usageActivityDayHref } from "$lib/usage-activity";
import {
  type UsagePeriodQuery,
  usagePeriodFromQuery,
  usagePeriodHref,
  usagePeriodKey,
} from "$lib/usage-period";

const dashboard = getAccountDashboard();
let activityDays = $state<UsageActivityDayRead[] | null>(null);
let activityError = $state<AccountError | null>(null);
let dayDetail = $state<UsageActivityDayRead | null>(null);
let dayError = $state<AccountError | null>(null);
let dayReady = $state(false);
let dayRetry = $state(0);

const activityRange = accountActivityRange(new Date());
const selectedQuery = $derived(usagePeriodFromQuery(page.url.searchParams.get("period")));
const selectedDay = $derived(
  usageActivityDayFromQuery(page.url.searchParams.get("day"), activityRange),
);
let period = $derived<UsagePeriodRead | null>(
  dashboard.summary ? dashboard.summary.usage[usagePeriodKey(selectedQuery)] : null,
);

$effect(() => {
  void loadActivity();
});

$effect(() => {
  const date = selectedDay;
  void dayRetry;
  if (!date) {
    dayDetail = null;
    dayError = null;
    dayReady = false;
    return;
  }
  dayReady = false;
  dayDetail = null;
  dayError = null;
  let cancelled = false;
  void fetchAccountActivity({ from: date, to: date }, "agents").then((result) => {
    if (cancelled) return;
    dayReady = true;
    if (result.status === "ok") {
      dayDetail = result.activity.days[0] ?? null;
      dayError = null;
      return;
    }
    dayError = result;
    dayDetail = null;
  });
  return () => {
    cancelled = true;
  };
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

function selectPeriod(query: UsagePeriodQuery): void {
  void goto(usagePeriodHref(page.url, query), {
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
    <UsagePeriodTabs {selectedQuery} onSelectQuery={selectPeriod} />
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
  {:else if period}
    <div class="summary-grid">
      <article
        ><span>Tokens</span><strong id="token-total"
          >{formatCount(period.totals.total_tokens)}</strong
        ><small id="token-split"
          >{`${formatCount(period.totals.input_tokens)} in · ${formatCount(period.totals.output_tokens)} out`}</small
        ></article
      >
      <article
        ><span>API-equivalent cost</span><strong id="cost-total">{formatCost(period.cost)}</strong
        ><small id="cost-basis">{costBasisLabel(period.cost)}</small></article
      >
    </div>
    <UsageBreakdown {period} />
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
    <UsageActivity
      days={activityDays}
      range={activityRange}
      selectedDate={selectedDay}
      detail={dayDetail}
      detailError={dayError}
      detailLoading={selectedDay !== null && !dayReady}
      onSelectDate={(date) => writeDay(date)}
      onClose={() => writeDay(null)}
      onRetryDetail={() => {
        dayRetry += 1;
      }}
    />
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
