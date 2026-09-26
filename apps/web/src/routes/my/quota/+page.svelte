<script lang="ts">
import { quotaPace } from "@gotry-io/quota-model";
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import { accountStatusLine, meterTone } from "$lib/account-overview";
import { getAccountStore } from "$lib/account-store.svelte.ts";
import { askingCopy } from "$lib/collection-demand";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import NextResets from "$lib/components/NextResets.svelte";
import PageHeader from "$lib/components/PageHeader.svelte";
import PageSection from "$lib/components/PageSection.svelte";
import QuotaRing from "$lib/components/QuotaRing.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import SetupBlock from "$lib/components/SetupBlock.svelte";
import SubscriptionList from "$lib/components/SubscriptionList.svelte";
import { paceHeadline, resetCopy, usageModelDisplayName } from "$lib/format";
import { fetchProviderStatus } from "$lib/provider-status";
import {
  isCurrent,
  nextResets,
  tightestWindow,
  windowAttribution,
  windowAttributionRange,
} from "$lib/quota-overview";

const store = getAccountStore();
const summary = $derived(store.summary);
const now = $derived(store.now);
const count = $derived(summary?.subscriptions.length ?? null);
const tightest = $derived(summary ? tightestWindow(summary.subscriptions, now) : null);
const lanes = $derived(summary ? nextResets(summary.subscriptions, now) : []);
const notCurrent = $derived(
  summary ? summary.subscriptions.filter((item) => !isCurrent(item, now)).length : 0,
);
/** Windows other than the tightest whose current rate runs out before their reset. */
const atRisk = $derived.by(() => {
  if (!summary) return 0;
  let risky = 0;
  for (const subscription of summary.subscriptions) {
    if (!isCurrent(subscription, now)) continue;
    for (const window of subscription.snapshot.windows) {
      if (window === tightest?.window) continue;
      if (quotaPace(window, now).kind === "runs_out") risky += 1;
    }
  }
  return risky;
});
let layout = $state<"list" | "table">("list");
let providerStatus = $state<Map<string, { indicator: string; description: string }>>(new Map());

const tightTone = $derived(tightest ? meterTone(tightest.remaining) : "good");
const tightPace = $derived(tightest ? quotaPace(tightest.window, now) : null);
const tightReset = $derived(
  tightest?.window.resets_at ? resetCopy(tightest.window.resets_at, now) : null,
);
const attributionRange = $derived(tightest ? windowAttributionRange(tightest.window, now) : null);
const attributionEntry = $derived(
  attributionRange ? store.periodFor(attributionRange, { breakdown: true }) : undefined,
);
const attributionTop = $derived.by(() => {
  const agents = attributionEntry?.data?.agents;
  if (!tightest || !agents) return null;
  return windowAttribution(agents, tightest.subscription.provider)[0] ?? null;
});
const status = $derived.by(() => {
  if (!summary) return null;
  if (store.collectionWaitMacs !== null) return askingCopy(store.collectionWaitMacs);
  return accountStatusLine(summary, now);
});

$effect(() => {
  if (attributionRange) void store.ensurePeriod(attributionRange, { breakdown: true });
});

$effect(() => {
  let cancelled = false;
  void fetchProviderStatus().then((rows) => {
    if (!cancelled) providerStatus = new Map(rows.map((row) => [row.id, row]));
  });
  return () => {
    cancelled = true;
  };
});

// Someone opened the Quota page: ask the Macs once when what they sent is old, and again each
// time the tab comes back into view. A hidden tab has nobody to wait for (ADR 0063, ADR 0064).
let askedOnOpen = false;
$effect(() => {
  if (askedOnOpen || !store.summary) return;
  askedOnOpen = true;
  void store.demandCollection();
});

$effect(() => {
  const onVisibility = (): void => {
    if (document.visibilityState === "hidden") {
      store.stopCollectionDemand();
      return;
    }
    void store.refresh().then(() => store.demandCollection());
  };
  document.addEventListener("visibilitychange", onVisibility);
  return () => {
    document.removeEventListener("visibilitychange", onVisibility);
    store.stopCollectionDemand();
  };
});

function refresh(): void {
  void store.refresh().then(() => store.demandCollection());
}
</script>

<svelte:head>
  <title>Quota · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

<PageHeader>
  {#snippet eyebrow()}Quota{#if count !== null && count > 0}{` · ${count} ${count === 1 ? "subscription" : "subscriptions"}`}{/if}{/snippet}
  {#if count === null}
    Loading quota…
  {:else if count === 0}
    No subscriptions reported yet.
  {:else if tightest}
    <b>{tightest.name}</b> is the tightest at
    <b class="tone-{tightTone}">{Math.round(tightest.remaining)}%</b>.
    {#if atRisk > 0}
      <b>{atRisk} more {atRisk === 1 ? "window" : "windows"}</b> may run out before reset.
    {:else}
      Everything else has room until its reset.
    {/if}
  {:else}
    No subscription is current. The last readings are below.
  {/if}
  {#snippet controls()}
    {#if count}
      <div class="seg" role="group" aria-label="Layout">
        <button type="button" aria-pressed={layout === "list"} onclick={() => (layout = "list")}>List</button>
        <button type="button" aria-pressed={layout === "table"} onclick={() => (layout = "table")}>Table</button>
      </div>
    {/if}
  {/snippet}
  {#snippet meta()}
    {#if status}
      <span class="dashboard-status" role="status">{status}</span>
      {#if store.collectionWaitMacs === null}
        <button class="pill sm" type="button" onclick={refresh}>Refresh</button>
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

{#if !summary}
  {#if !store.loadError}
    <LoadingBlock lines={5} label="Loading quota" />
  {/if}
{:else if summary.subscriptions.length === 0}
  {#if summary.devices.length === 0}
    <SetupBlock title="Connect your first Mac" />
  {:else}
    <p class="empty-state">No quota windows yet. QuotaBar adds each provider it can read.</p>
  {/if}
{:else}
  {#if tightest}
    <section class="tight" aria-labelledby="tight-title">
      <QuotaRing remaining={tightest.remaining} size={104} label={`${Math.round(tightest.remaining)}%`} />
      <div class="tight-text">
        <span class="eyebrow">Tightest window</span>
        <h2 id="tight-title">
          {tightest.name}
          {tightTone === "critical"
            ? "is almost out."
            : tightTone === "warn"
              ? "is getting tight."
              : "has the least left."}
        </h2>
        <div class="tight-sub">
          <span><b>{Math.round(tightest.remaining)}%</b>{#if tightReset}{` · ${tightReset}`}{/if}</span>
          {#if tightPace && paceHeadline(tightPace, tightest.window.resets_at)}
            <span class:risk={tightPace.kind === "runs_out"}
              >{paceHeadline(tightPace, tightest.window.resets_at)}</span
            >
          {/if}
          {#if attributionTop && attributionTop.share >= 0.05}
            <span
              ><span class="model">{usageModelDisplayName(attributionTop.row.model)}</span> used about
              {Math.round(attributionTop.share * 100)}% of it.</span
            >
          {/if}
        </div>
      </div>
      <div class="tight-resets">
        <div class="resets-head">
          <span class="eyebrow">Next resets</span>
          <span class="resets-note">7 days · local time</span>
        </div>
        {#if lanes.length > 0}
          <NextResets {lanes} {now} />
        {:else}
          <p class="resets-note">Nothing refills in the next seven days.</p>
        {/if}
      </div>
    </section>
  {/if}

  <PageSection id="subscriptions-title" title="Subscriptions">
    {#snippet note()}{notCurrent > 0
        ? `${notCurrent} not current`
        : "Every reading is current"}{/snippet}
    <SubscriptionList
      {summary}
      selectors={store.subscriptionSelectors}
      {now}
      {layout}
      {providerStatus}
    />
  </PageSection>
{/if}

<style>
:global(.page-header h1 b.tone-warn) {
  color: var(--quota-warning);
}

:global(.page-header h1 b.tone-critical) {
  color: var(--quota-critical);
}

.tight {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) minmax(0, 1.3fr);
  gap: 24px 36px;
  align-items: center;
  padding: 22px 0 36px;
  border-top: 1px solid var(--hairline);
}

.tight h2 {
  margin-top: 4px;
  font-family: var(--rounded);
  font-size: 22px;
  font-weight: 500;
  line-height: 1.25;
}

.tight-sub {
  display: grid;
  gap: 2px;
  margin-top: 6px;
  color: var(--body);
  font-size: 13px;
}

.tight-sub b {
  color: var(--ink);
}

.risk {
  color: var(--quota-warning);
}

.model {
  color: var(--ink);
  font-family: var(--mono);
  font-size: 0.92em;
}

.tight-resets {
  display: grid;
  gap: 6px;
  min-width: 0;
}

.resets-head {
  display: flex;
  justify-content: space-between;
  gap: 8px;
}

.resets-note {
  color: var(--body);
  font-size: 12px;
}

@media (max-width: 960px) {
  .tight {
    grid-template-columns: auto minmax(0, 1fr);
  }

  .tight-resets {
    grid-column: 1 / -1;
  }
}
</style>
