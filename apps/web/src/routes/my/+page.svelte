<script lang="ts">
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import { accountStatusLine, devicesSummaryLine, topUsageModel } from "$lib/account-overview";
import { getAccountStore } from "$lib/account-store.svelte.ts";
import { askingCopy } from "$lib/collection-demand";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import PageHeader from "$lib/components/PageHeader.svelte";
import PageSection from "$lib/components/PageSection.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import SubscriptionCards from "$lib/components/SubscriptionCards.svelte";
import { costBasisLabel, formatCost, formatCount } from "$lib/format";
import { DEVICES_PATH, USAGE_PATH } from "$lib/routes";

const store = getAccountStore();
const now = $derived(store.now);
let today = $derived(store.summary?.usage.today ?? null);
let topModel = $derived(topUsageModel(today));
const status = $derived.by(() => {
  if (!store.summary) return null;
  if (store.collectionWaitMacs !== null) return askingCopy(store.collectionWaitMacs);
  return accountStatusLine(store.summary, now);
});

// Someone opened the dashboard: ask the Macs once when what they sent is old, and again each
// time the tab comes back into view. A hidden tab has nobody to wait for.
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
</script>

<svelte:head>
  <title>Home · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

<PageHeader>
  {#snippet eyebrow()}Home{/snippet}
  {#if today && store.summary}
    You ran <b>{formatCount(today.totals.total_tokens)} tokens</b> today, across
    <b
      >{store.summary.subscriptions.length}
      {store.summary.subscriptions.length === 1 ? "subscription" : "subscriptions"}</b
    >.
  {:else}
    Your subscriptions and today's Usage.
  {/if}
  {#snippet meta()}
    {#if status}
      <span class="dashboard-status">{status}</span>
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

<PageSection id="quota-title" title="Subscriptions">
  {#if !store.summary}
    {#if !store.loadError}
      <LoadingBlock lines={4} label="Loading subscriptions" />
    {/if}
  {:else}
    <SubscriptionCards
      summary={store.summary}
      selectors={store.subscriptionSelectors}
      {now}
    />
  {/if}
</PageSection>

<PageSection id="today-title" title="Today">
  {#if !today}
    {#if !store.loadError}
      <LoadingBlock lines={2} label="Loading today" />
    {/if}
  {:else}
    <a class="today-strip" href={`${USAGE_PATH}?period=day`} aria-labelledby="today-title">
      <article>
        <span>Tokens</span>
        <strong>{formatCount(today.totals.total_tokens)}</strong>
        <small
          >{`${formatCount(today.totals.input_tokens)} in · ${formatCount(today.totals.output_tokens)} out`}</small
        >
      </article>
      <article>
        <span>API-equivalent cost</span>
        <strong>{formatCost(today.cost)}</strong>
        <small>{costBasisLabel(today.cost)}</small>
      </article>
      <article>
        <span>Top model</span>
        <strong>{topModel}</strong>
      </article>
    </a>
  {/if}
</PageSection>

{#if store.summary && (store.summary.devices.length > 0 || store.summary.subscriptions.length > 0)}
  <PageSection id="home-devices-title" title="Devices" titleHidden>
    <a class="devices-strip" href={DEVICES_PATH}>{devicesSummaryLine(store.summary.devices, now)}</a>
  </PageSection>
{/if}
