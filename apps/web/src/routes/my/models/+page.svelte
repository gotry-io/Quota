<script lang="ts">
import { formatWindowTitle, remainingPercent } from "@gotry-io/quota-model";
import {
  inferenceProviderDisplayName,
  agentDisplayName,
  providerDisplayName,
} from "@gotry-io/quota-protocol";
import { goto } from "$app/navigation";
import { page } from "$app/state";
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import { meterTone } from "$lib/account-overview";
import { getAccountStore } from "$lib/account-store.svelte.ts";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import MetricTabs from "$lib/components/MetricTabs.svelte";
import ModelLedger from "$lib/components/ModelLedger.svelte";
import ModelRiver from "$lib/components/ModelRiver.svelte";
import PageHeader from "$lib/components/PageHeader.svelte";
import PageSection from "$lib/components/PageSection.svelte";
import PeriodControl from "$lib/components/PeriodControl.svelte";
import QuotaMeter from "$lib/components/QuotaMeter.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import SetupBlock from "$lib/components/SetupBlock.svelte";
import { formatCost, formatCount, usageModelDisplayName } from "$lib/format";
import { modelColor } from "$lib/model-colors";
import { costPerMessageMicrousd, namedModelCount } from "$lib/model-usage";
import {
  isCurrent,
  subscriptionAgents,
  windowAttribution,
  windowAttributionRange,
} from "$lib/quota-overview";
import { MODELS_PATH, subscriptionPath } from "$lib/routes";
import { cacheHitLabel } from "$lib/usage-metrics";
import {
  type UsagePeriodSelection,
  usagePeriodFromUrl,
  usagePeriodHref,
  usagePeriodName,
  usagePeriodPhrase,
} from "$lib/usage-period";
import { shortDate } from "$lib/usage-insights";
import { createUsageView } from "$lib/usage-view.svelte.ts";

type Metric = "tokens" | "cost";

const store = getAccountStore();
const selection = $derived(usagePeriodFromUrl(page.url));
const view = createUsageView(store, () => selection);
let metric = $state<Metric>("tokens");
let highlight = $state<string | null>(null);

const summary = $derived(store.summary);
const noMac = $derived(summary !== null && summary.devices.length === 0);
const period = $derived(view.period);
const total = $derived(period?.totals.total_tokens ?? 0);
const count = $derived(namedModelCount(view.rows));
const asked = $derived(page.url.searchParams.get("model"));
const selected = $derived(view.rows.find((row) => row.model === asked) ?? view.rows[0] ?? null);
const second = $derived(view.rows.find((row) => row.key !== view.rows[0]?.key) ?? null);
const river = $derived(view.river(metric));
const tokensRiver = $derived(view.river("tokens"));
const selectedDaily = $derived(
  selected && tokensRiver
    ? (tokensRiver.bands.find((band) => band.key === selected.key)?.values ?? null)
    : null,
);
const dailyMax = $derived(selectedDaily ? Math.max(1, ...selectedDaily) : 1);

/** The plan window this model's agents spend, the tightest one at least a day long. */
const quotaWindow = $derived.by(() => {
  if (!selected || !summary) return null;
  const agents = new Set(selected.agents.map((sent) => sent.agent));
  let best: {
    subscription: (typeof summary.subscriptions)[number];
    window: (typeof summary.subscriptions)[number]["snapshot"]["windows"][number];
    range: { from: string; to: string };
    remaining: number;
  } | null = null;
  for (const subscription of summary.subscriptions) {
    if (!isCurrent(subscription, store.now)) continue;
    if (!subscriptionAgents(subscription.provider).some((agent) => agents.has(agent))) continue;
    for (const window of subscription.snapshot.windows) {
      const range = windowAttributionRange(window, store.now);
      if (!range) continue;
      const remaining = remainingPercent(window.used_percent);
      if (best === null || remaining < best.remaining)
        best = { subscription, window, range, remaining };
    }
  }
  return best;
});
const quotaEntry = $derived(
  quotaWindow ? store.periodFor(quotaWindow.range, { breakdown: true }) : undefined,
);
const quotaShare = $derived.by(() => {
  const agents = quotaEntry?.data?.agents;
  if (!quotaWindow || !agents || !selected) return null;
  const shares = windowAttribution(agents, quotaWindow.subscription.provider);
  return shares.find((item) => item.row.key === selected.key)?.share ?? 0;
});

$effect(() => {
  if (quotaWindow) void store.ensurePeriod(quotaWindow.range, { breakdown: true });
});

function selectPeriod(next: UsagePeriodSelection): void {
  void goto(usagePeriodHref(page.url, next), {
    replaceState: true,
    keepFocus: true,
    noScroll: true,
  });
}

function modelHref(model: string): string {
  const href = new URL(page.url);
  href.searchParams.set("model", model);
  return `${MODELS_PATH}${href.search}`;
}

function formatMetric(value: number): string {
  return metric === "cost"
    ? formatCost({ amount_microusd: String(Math.round(value)), status: "complete" })
    : formatCount(value);
}

function percent(part: number, whole: number): number {
  return whole > 0 ? Math.round((part / whole) * 100) : 0;
}

const perMessage = $derived.by(() => {
  if (!selected) return "—";
  const microusd = costPerMessageMicrousd(selected);
  return microusd === null ? "—" : `$${(microusd / 1_000_000).toFixed(3)}`;
});
</script>

<svelte:head>
  <title>Models · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

<PageHeader>
  {#snippet eyebrow()}Models · {usagePeriodName(selection)}{/snippet}
  {#if noMac}
    No models yet.
  {:else if !period}
    Loading your models…
  {:else if count === 0}
    No model ran {usagePeriodPhrase(selection, store.now)}.
  {:else if view.arrival}
    <b>{count} {count === 1 ? "model" : "models"}</b>.
    <b class="model">{view.arrival.model}</b> arrived on <b>{shortDate(view.arrival.date)}</b> and
    carried
    <b
      >{percent(
        view.rows.find((row) => row.model === view.arrival?.model)?.totals.total_tokens ?? 0,
        total,
      )}%</b
    > of your tokens.
  {:else}
    <b>{count} {count === 1 ? "model" : "models"}</b>
    {usagePeriodPhrase(selection, store.now)}.{#if view.rows[0] && count > 1}
      {" "}<b class="model">{usageModelDisplayName(view.rows[0].model)}</b> carried
      <b>{percent(view.rows[0].totals.total_tokens, total)}%</b>{#if second}; <b class="model"
          >{usageModelDisplayName(second.model)}</b
        >
        <b>{percent(second.totals.total_tokens, total)}%</b>{/if}.{/if}
  {/if}
  {#snippet controls()}
    {#if !noMac}
      <PeriodControl
        {selection}
        today={store.now}
        earliest={store.activityRange.from}
        onSelect={selectPeriod}
      />
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
  <section class="share-chart" aria-labelledby="share-title">
    <h2 id="share-title" class="visually-hidden">Share of each day</h2>
    <MetricTabs
      label="Metric"
      panelId="share-panel"
      selected={metric}
      onSelect={(next) => (metric = next)}
      tabs={[
        { metric: "tokens", label: "Tokens" },
        { metric: "cost", label: "API-equivalent cost" },
      ]}
    >
      {#snippet trailing()}Share of each day{/snippet}
    </MetricTabs>
    <div id="share-panel" role="tabpanel">
      {#if river}
        <ModelRiver
          data={river}
          mode="share"
          height={240}
          colors={view.colors}
          format={formatMetric}
          label={`Share of each day's ${metric === "cost" ? "API-equivalent cost" : "tokens"} by model, ${usagePeriodName(selection)}`}
          {highlight}
          onHighlight={(key) => (highlight = key)}
        />
      {:else if view.fromSummary}
        <p class="note">The chart draws up to a year by day. Choose a shorter period to see it.</p>
      {:else}
        <LoadingBlock lines={3} label="Loading the chart" />
      {/if}
    </div>
  </section>

  <PageSection id="every-model-title" title="Every model">
    {#snippet note()}Names merged across agents and aliases · choose one{/snippet}
    {#if view.rows.length > 0}
      <ModelLedger
        rows={view.rows}
        previous={view.previousRows}
        colors={view.colors}
        limit={null}
        detail
        selected={selected?.key ?? null}
        {highlight}
        onHighlight={(key) => (highlight = key)}
        rowHref={(row) => modelHref(row.model)}
        caption="Every model in this period"
      />
    {:else}
      <p class="empty-state">No model breakdown for this period.</p>
    {/if}
  </PageSection>

  {#if selected}
    {@const color = modelColor(view.colors, selected.provider, selected.model)}
    <div class="aside">
      <section class="selected" aria-labelledby="selected-title">
        <div class="heading">
          <h2 id="selected-title">
            <i class="swatch" style:background={color}></i>
            <span class="model">{usageModelDisplayName(selected.model)}</span>
          </h2>
          <p>{inferenceProviderDisplayName(selected.provider)} · {usagePeriodName(selection)}</p>
        </div>
        {#if selectedDaily}
          <svg
            class="daily"
            viewBox="0 0 {selectedDaily.length * 20} 70"
            preserveAspectRatio="none"
            role="img"
            aria-label={`${selected.model} tokens per day`}
          >
            {#each selectedDaily as value, index (index)}
              {#if value > 0}
                <rect
                  x={index * 20 + 2}
                  y={66 - (value / dailyMax) * 62}
                  width="16"
                  height={(value / dailyMax) * 62}
                  rx="2"
                  fill={color}
                />
              {:else}
                <rect x={index * 20 + 2} y="64" width="16" height="2" class="empty-day" />
              {/if}
            {/each}
          </svg>
        {:else if view.riverRange && !view.fromSummary}
          <p class="note">Daily detail covers the eight largest models of the period.</p>
        {/if}
        <dl class="facts">
          <div><dt>Tokens</dt><dd>{formatCount(selected.totals.total_tokens)}</dd></div>
          <div><dt>API-equivalent</dt><dd>{formatCost(selected.cost)}</dd></div>
          <div><dt>Per message</dt><dd>{perMessage}</dd></div>
          <div><dt>From cache</dt><dd>{cacheHitLabel(selected.totals) ?? "—"}</dd></div>
        </dl>
        <div class="agents">
          <span class="note">Agents</span>
          <div class="split" aria-hidden="true">
            {#each selected.agents as sent, index (sent.agent)}
              <i style:flex-grow={sent.tokens} class:first={index === 0}></i>
            {/each}
          </div>
          <span class="note"
            >{selected.agents
              .map((sent) => `${agentDisplayName(sent.agent)} ${percent(sent.tokens, selected.totals.total_tokens)}%`)
              .join(" · ")}</span
          >
        </div>
      </section>
      <PageSection id="in-quota-title" title="In your quota">
        {#if quotaWindow}
          {@const title = `${providerDisplayName(quotaWindow.subscription.provider)} ${formatWindowTitle(quotaWindow.window.title, quotaWindow.window)}`}
          {@const sel = store.subscriptionSelectors[quotaWindow.subscription.key]}
          {#if quotaShare !== null}
            <p class="quota-sentence">
              <span class="model">{selected.model}</span> used about
              <b>{Math.round(quotaShare * 100)}%</b> of <b>{title}</b> so far, which has
              <b class="tone-{meterTone(quotaWindow.remaining)}">{Math.round(quotaWindow.remaining)}%</b> left.
            </p>
          {:else}
            <LoadingBlock lines={2} label="Estimating the window" />
          {/if}
          <QuotaMeter remaining={quotaWindow.remaining} thick />
          {#if sel}
            <a class="link" href={subscriptionPath(sel)}>Open the window →</a>
          {/if}
          <p class="note">
            Estimated from this Account's hourly Usage inside the window. Providers do not report
            per-model quota.
          </p>
        {:else}
          <p class="note">
            Sent through {selected.agents.map((sent) => agentDisplayName(sent.agent)).join(", ")},
            with no plan window of a day or longer reported for it.
          </p>
        {/if}
      </PageSection>
    </div>
  {/if}
{/if}

<style>
.share-chart {
  display: grid;
  gap: 16px;
  padding: 22px 0 36px;
  border-top: 1px solid var(--hairline);
}

.note {
  color: var(--body);
  font-size: 12.5px;
}

.model {
  font-family: var(--mono);
  font-size: 0.92em;
}

:global(.page-header h1 b.model) {
  font-family: var(--mono);
  font-size: 0.92em;
  font-weight: 400;
}

.aside {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 300px;
  gap: 0 48px;
  align-items: start;
}

.selected {
  display: grid;
  gap: 16px;
  min-width: 0;
  padding: 22px 0 36px;
  border-top: 1px solid var(--hairline);
}

.heading {
  display: flex;
  flex-wrap: wrap;
  gap: 8px 16px;
  align-items: baseline;
  justify-content: space-between;
}

.heading h2 {
  display: flex;
  gap: 10px;
  align-items: center;
  font-family: var(--rounded);
  font-size: 19px;
  font-weight: 500;
}

.heading p {
  color: var(--body);
  font-size: 13px;
}

.swatch {
  width: 12px;
  height: 12px;
  border-radius: 3px;
}

.daily {
  display: block;
  width: 100%;
  height: 70px;
}

.empty-day {
  fill: var(--meter-track);
}

.facts {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 12px 20px;
  margin: 0;
}

.facts div {
  display: grid;
  gap: 1px;
}

.facts dt {
  color: var(--body);
  font-size: 12px;
}

.facts dd {
  margin: 0;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}

.agents {
  display: grid;
  gap: 6px;
}

.split {
  display: flex;
  gap: 2px;
  height: 8px;
  overflow: hidden;
  border-radius: 9999px;
}

.split i {
  flex-basis: 0;
  background: var(--muted);
}

.split i.first {
  background: var(--ink);
}

.quota-sentence {
  color: var(--body);
  font-size: 15px;
}

.quota-sentence b {
  color: var(--ink);
}

.quota-sentence b.tone-warn {
  color: var(--quota-warning);
}

.quota-sentence b.tone-critical {
  color: var(--quota-critical);
}

@media (max-width: 960px) {
  .aside {
    grid-template-columns: minmax(0, 1fr);
  }

  .facts {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}
</style>
