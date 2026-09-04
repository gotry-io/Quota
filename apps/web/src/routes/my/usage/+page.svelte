<script lang="ts">
import type { UsagePeriodRead } from "@gotry-io/quota-protocol";
import { goto } from "$app/navigation";
import { page } from "$app/state";
import { activityRangeKey, getAccountStore } from "$lib/account-store.svelte.ts";
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

const store = getAccountStore();
const activityRange = store.activityRange;
const rangeKey = activityRangeKey(activityRange);

const selectedQuery = $derived(usagePeriodFromQuery(page.url.searchParams.get("period")));
const selectedDay = $derived(
  usageActivityDayFromQuery(page.url.searchParams.get("day"), activityRange),
);
let period = $derived<UsagePeriodRead | null>(
  store.summary ? store.summary.usage[usagePeriodKey(selectedQuery)] : null,
);
const activityEntry = $derived(store.activity[rangeKey]);
const activityDays = $derived(activityEntry?.data ?? null);
const activityError = $derived(activityEntry?.status === "error" ? activityEntry.error : null);
const detailEntry = $derived(selectedDay ? store.dayDetail[selectedDay] : undefined);
const dayDetail = $derived(detailEntry?.data ?? null);
const dayError = $derived(detailEntry?.error ?? null);
const detailLoading = $derived(
  selectedDay !== null &&
    (detailEntry === undefined ||
      detailEntry.status === "idle" ||
      detailEntry.status === "loading"),
);

$effect(() => {
  const date = selectedDay;
  if (!date) return;
  void store.ensureDay(date);
});

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
