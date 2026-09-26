<script lang="ts">
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import { accountStatusLine } from "$lib/account-overview";
import { getAccountStore } from "$lib/account-store.svelte.ts";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import PageHeader from "$lib/components/PageHeader.svelte";
import PageSection from "$lib/components/PageSection.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import SubscriptionCards from "$lib/components/SubscriptionCards.svelte";

const store = getAccountStore();
const count = $derived(store.summary?.subscriptions.length ?? null);
</script>

<svelte:head>
  <title>Quota · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

<PageHeader>
  {#snippet eyebrow()}Quota{/snippet}
  {#if count === null}
    Loading quota…
  {:else if count === 0}
    No subscriptions reported yet.
  {:else}
    <b>{count} {count === 1 ? "subscription" : "subscriptions"}</b>, with what is left on each
    window and when it resets.
  {/if}
  {#snippet meta()}
    {#if store.summary}
      <span class="dashboard-status">{accountStatusLine(store.summary, store.now)}</span>
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

<PageSection id="subscriptions-title" title="Subscriptions">
  {#if !store.summary}
    {#if !store.loadError}
      <LoadingBlock lines={4} label="Loading subscriptions" />
    {/if}
  {:else}
    <SubscriptionCards
      summary={store.summary}
      selectors={store.subscriptionSelectors}
      now={store.now}
    />
  {/if}
</PageSection>
