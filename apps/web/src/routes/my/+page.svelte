<script lang="ts">
import { goto } from "$app/navigation";
import { page } from "$app/state";
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import { usageGapsNote } from "$lib/account-overview";
import { activityRangeKey, getAccountStore } from "$lib/account-store.svelte.ts";
import AgentFlow from "$lib/components/AgentFlow.svelte";
import Insights from "$lib/components/Insights.svelte";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import MetricTabs from "$lib/components/MetricTabs.svelte";
import ModelLedger from "$lib/components/ModelLedger.svelte";
import ModelRiver from "$lib/components/ModelRiver.svelte";
import PageHeader from "$lib/components/PageHeader.svelte";
import PageSection from "$lib/components/PageSection.svelte";
import PeriodControl from "$lib/components/PeriodControl.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import SetupBlock from "$lib/components/SetupBlock.svelte";
import TokenMix from "$lib/components/TokenMix.svelte";
import UsageActivity from "$lib/components/UsageActivity.svelte";
import { formatCost, formatCount, usageModelDisplayName } from "$lib/format";
import { agentModelFlow, foldModelRows, namedModelCount } from "$lib/model-usage";
import type { RiverMode } from "$lib/model-river";
import { tightestWindow } from "$lib/quota-overview";
import { MODELS_PATH, subscriptionPath } from "$lib/routes";
import { usageActivityDayFromQuery, usageActivityDayHref } from "$lib/usage-activity";
import { accountPeriodExportInput, WEB_APP_VERSION } from "$lib/usage-export";
import { usageInsights, usageRecords } from "$lib/usage-insights";
import { cacheHitLabel, costPricedLabel } from "$lib/usage-metrics";
import {
  previousUsagePeriodName,
  type UsagePeriodSelection,
  usagePeriodFromUrl,
  usagePeriodHref,
  usagePeriodName,
  usagePeriodPhrase,
  usageRangeDays,
} from "$lib/usage-period";
import { createUsageView } from "$lib/usage-view.svelte.ts";

type Metric = "tokens" | "cost" | "messages";

const store = getAccountStore();
const selection = $derived(usagePeriodFromUrl(page.url));
const view = createUsageView(store, () => selection);

let metric = $state<Metric>("tokens");
let mode = $state<RiverMode>("amount");
let highlight = $state<string | null>(null);

const summary = $derived(store.summary);
const noMac = $derived(summary !== null && summary.devices.length === 0);
const period = $derived(view.period);
const total = $derived(period?.totals.total_tokens ?? 0);
const modelCount = $derived(namedModelCount(view.rows));
const top = $derived(view.rows[0] ?? null);
const river = $derived(view.river(metric));
const riverMode = $derived<RiverMode>(metric === "messages" ? "amount" : mode);

const activityRange = $derived(store.activityRange);
const activityEntry = $derived(store.activity[activityRangeKey(activityRange)]);
const activityDays = $derived(activityEntry?.data ?? null);
const activityError = $derived(activityEntry?.status === "error" ? activityEntry.error : null);
const selectedDay = $derived(
  usageActivityDayFromQuery(page.url.searchParams.get("day"), activityRange),
);
const detailEntry = $derived(selectedDay ? store.dayDetail[selectedDay] : undefined);

const rhythm = $derived(view.range ? store.rhythm[activityRangeKey(view.range)]?.data : null);

const previousTotal = $derived(view.previousPeriod?.totals.total_tokens ?? null);
const change = $derived(
  previousTotal !== null && previousTotal > 0 && total > 0
    ? Math.round((total / previousTotal - 1) * 100)
    : null,
);
const activeDays = $derived(
  view.read ? view.read.days.filter((day) => day.totals.total_tokens > 0).length : null,
);
const spanDays = $derived(view.range ? usageRangeDays(view.range) : null);
const flags = $derived(period ? usageGapsNote(period.partial, view.truncated) : null);

const tightest = $derived(summary ? tightestWindow(summary.subscriptions, store.now) : null);
const insights = $derived(
  period
    ? usageInsights({
        rows: view.rows,
        previous: view.previousRows,
        totals: period.totals,
        cacheSaved: period.cache_saved,
        arrival: view.arrival,
        tightest: tightest
          ? {
              name: tightest.name,
              remaining: tightest.remaining,
              href: store.subscriptionSelectors[tightest.subscription.key]
                ? subscriptionPath(store.subscriptionSelectors[tightest.subscription.key] ?? "")
                : null,
            }
          : null,
        rhythm: rhythm
          ? {
              hours: rhythm.hours_of_day.map((hour) => hour.total_tokens),
              weekdays: rhythm.weekday_hours.map((row) =>
                row.reduce((sum, value) => sum + value, 0),
              ),
            }
          : null,
      })
    : [],
);
const allRows = $derived(summary ? foldModelRows(summary.usage.all.agents) : []);
const records = $derived(
  activityDays ? usageRecords({ days: activityDays, range: activityRange, allRows }) : [],
);
const flow = $derived(agentModelFlow(view.rows));
const exportInput = $derived(
  view.read
    ? accountPeriodExportInput(view.read, {
        exportedAt: store.now.toISOString(),
        appVersion: WEB_APP_VERSION,
      })
    : null,
);

$effect(() => {
  void store.ensureActivity(activityRange);
});

$effect(() => {
  if (view.range) void store.ensureRhythm(view.range);
});

$effect(() => {
  if (selectedDay) void store.ensureDay(selectedDay);
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

function modelHref(model: string): string {
  const params = new URLSearchParams(page.url.search);
  params.delete("day");
  params.set("model", model);
  return `${MODELS_PATH}?${params.toString()}`;
}

function formatMetric(value: number): string {
  if (metric === "cost") {
    return formatCost({ amount_microusd: String(Math.round(value)), status: "complete" });
  }
  return formatCount(value);
}
</script>

<svelte:head>
  <title>Home · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

<PageHeader>
  {#snippet eyebrow()}Home · {usagePeriodName(selection)}{/snippet}
  {#if noMac}
    Your models will show up here.
  {:else if !period}
    Loading your models…
  {:else if total === 0}
    No usage {usagePeriodPhrase(selection, store.now)}.
  {:else}
    You ran <b>{formatCount(total)} tokens</b> through
    <b>{modelCount} {modelCount === 1 ? "model" : "models"}</b>
    {usagePeriodPhrase(selection, store.now)}.{#if top && modelCount > 1}
      {" "}<b class="model">{usageModelDisplayName(top.model)}</b> carried
      <b>{Math.round((top.totals.total_tokens / total) * 100)}%</b> of it.{/if}
  {/if}
  {#snippet controls()}
    {#if !noMac}
      <PeriodControl
        {selection}
        today={store.now}
        earliest={activityRange.from}
        onSelect={selectPeriod}
        {exportInput}
      />
    {/if}
  {/snippet}
  {#snippet meta()}
    {#if period && total > 0}
      <span><b>{formatCost(period.cost)}</b> API-equivalent</span>
      {#if cacheHitLabel(period.totals)}
        <span><b>{cacheHitLabel(period.totals)}</b> of input from cache</span>
      {/if}
      {#if activeDays !== null && spanDays !== null && spanDays > 1}
        <span><b>{activeDays}</b> of {spanDays} days active</span>
      {/if}
      {#if change !== null}
        <span
          ><b>{change > 0 ? "↑" : change < 0 ? "↓" : ""} {Math.abs(change)}%</b> tokens vs {previousUsagePeriodName(
            selection,
          )}</span
        >
      {/if}
      {#if flags}
        <span>{flags}</span>
      {/if}
    {/if}
  {/snippet}
</PageHeader>

{#if store.loadError}
  <RetryNotice
    message={store.loadError.message}
    actionLabel={accountNoticeActionLabel(store.loadError)}
    onRetry={accountNoticeRetry(store.loadError, () => void store.refresh())}
  />
{/if}
{#if view.error}
  <RetryNotice
    message={view.error.message}
    actionLabel={accountNoticeActionLabel(view.error)}
    onRetry={accountNoticeRetry(view.error, () => view.retry())}
  />
{/if}

{#if noMac}
  <SetupBlock title="Connect your first Mac" />
{:else if !period}
  {#if !store.loadError && !view.error}
    <LoadingBlock lines={6} label="Loading your models" />
  {/if}
{:else}
  <section class="usage-chart" aria-labelledby="usage-chart-title">
    <h2 id="usage-chart-title" class="visually-hidden">Usage by model</h2>
    <MetricTabs
      label="Metric"
      panelId="usage-chart-panel"
      selected={metric}
      onSelect={(next) => (metric = next)}
      tabs={[
        { metric: "tokens", label: "Tokens", value: formatCount(period.totals.total_tokens) },
        { metric: "cost", label: "API-equivalent cost", value: formatCost(period.cost) },
        { metric: "messages", label: "Messages", value: formatCount(period.totals.messages) },
      ]}
    >
      {#snippet trailing()}
        <div class="seg" role="group" aria-label="Scale">
          <button type="button" aria-pressed={riverMode === "amount"} onclick={() => (mode = "amount")}
            >Amount</button
          >
          <button
            type="button"
            aria-pressed={riverMode === "share"}
            disabled={metric === "messages"}
            onclick={() => (mode = "share")}>Share</button
          >
        </div>
      {/snippet}
    </MetricTabs>
    <div id="usage-chart-panel" role="tabpanel" class="usage-chart-panel">
      {#if metric === "cost"}
        <p class="chart-note" id="cost-basis">{costPricedLabel(period.cost)}</p>
      {:else if metric === "messages"}
        <p class="chart-note">Messages are counted by day, not by model.</p>
      {/if}
      {#if river}
        <ModelRiver
          data={river}
          mode={riverMode}
          colors={view.colors}
          format={formatMetric}
          label={`${metric === "cost" ? "API-equivalent cost" : metric === "messages" ? "Messages" : "Tokens"} by model per day, ${usagePeriodName(selection)}`}
          fill={metric === "messages" ? "var(--chart-input)" : undefined}
          {highlight}
          onHighlight={(key) => (highlight = key)}
        />
      {:else if view.fromSummary}
        <p class="chart-note">The chart draws up to a year by day. Choose a shorter period to see it.</p>
      {:else}
        <LoadingBlock lines={3} label="Loading the chart" />
      {/if}
      {#if view.rows.length > 0}
        <ModelLedger
          rows={view.rows}
          previous={view.previousRows}
          colors={view.colors}
          {highlight}
          onHighlight={(key) => (highlight = key)}
          rowHref={(row) => modelHref(row.model)}
          moreHref={modelHref(view.rows[6]?.model ?? "")}
          caption="Models in this period"
        />
      {:else}
        <p class="empty-state">No model breakdown for this period.</p>
      {/if}
    </div>
  </section>

  {#if insights.length > 0}
    <PageSection id="insights-title" title="What stood out">
      {#snippet note()}Written from your numbers{/snippet}
      <Insights {insights} />
    </PageSection>
  {/if}

  <div class="columns">
    <PageSection id="mix-title" title="Where the tokens went">
      {#snippet note()}Input and output{/snippet}
      <TokenMix totals={period.totals} cacheSaved={period.cache_saved} />
    </PageSection>
    <PageSection id="year-title" title="Your year">
      {#snippet note()}UTC · choose a day to open it{/snippet}
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
          detail={detailEntry?.data ?? null}
          detailError={detailEntry?.error ?? null}
          detailLoading={selectedDay !== null &&
            (detailEntry === undefined || detailEntry.status === "idle" || detailEntry.status === "loading")}
          colors={view.colors}
          onSelectDate={(date) => writeDay(date)}
          onClose={() => writeDay(null)}
          onRetryDetail={() => {
            if (selectedDay) void store.ensureDay(selectedDay, { maxAgeMs: 0 });
          }}
        />
      {:else if activityError}
        <RetryNotice
          message={activityError.message}
          actionLabel={accountNoticeActionLabel(activityError)}
          onRetry={accountNoticeRetry(activityError, () =>
            void store.ensureActivity(activityRange, { maxAgeMs: 0 }),
          )}
        />
      {:else}
        <LoadingBlock lines={4} label="Loading Usage activity" />
      {/if}
    </PageSection>
  </div>

  {#if flow.links.length > 0 || records.length > 0}
    <PageSection id="flow-title" title="Agents → models">
      {#snippet note()}Which agent sent work to which model{/snippet}
      {#if flow.links.length > 0}
        <AgentFlow {flow} colors={view.colors} />
      {/if}
      {#if records.length > 0}
        <dl class="records" aria-label="Records">
          {#each records as record (record.id)}
            <div>
              <dt>{record.label}</dt>
              <dd class="record-value">{record.value}</dd>
              <dd class="record-note" class:model={record.model}>{record.note}</dd>
            </div>
          {/each}
        </dl>
      {/if}
    </PageSection>
  {/if}
{/if}

<style>
.usage-chart {
  display: grid;
  gap: 16px;
  padding: 22px 0 36px;
  border-top: 1px solid var(--hairline);
}

.usage-chart-panel {
  display: grid;
  gap: 16px;
  min-width: 0;
}

.chart-note {
  color: var(--body);
  font-size: 12.5px;
}

:global(.page-header h1 b.model) {
  font-family: var(--mono);
  font-size: 0.92em;
  font-weight: 400;
}

.columns {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0 48px;
}

.records {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 16px;
  margin: 8px 0 0;
}

.records div {
  display: grid;
  gap: 1px;
}

.records dt,
.record-note {
  color: var(--body);
  font-size: 12px;
}

.records dd {
  margin: 0;
}

.record-value {
  font-family: var(--rounded);
  font-size: 22px;
  font-variant-numeric: tabular-nums;
  font-weight: 500;
}

.record-note.model {
  font-family: var(--mono);
}

@media (max-width: 960px) {
  .columns {
    grid-template-columns: minmax(0, 1fr);
  }

  .records {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}
</style>
