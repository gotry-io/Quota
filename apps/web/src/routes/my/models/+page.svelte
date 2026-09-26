<script lang="ts">
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import { getAccountStore } from "$lib/account-store.svelte.ts";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import PageHeader from "$lib/components/PageHeader.svelte";
import PageSection from "$lib/components/PageSection.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import UsageBreakdown from "$lib/components/UsageBreakdown.svelte";
import { formatCount, usageModelDisplayName } from "$lib/format";
import { usageModelShares } from "$lib/usage-metrics";

const store = getAccountStore();
const period = $derived(store.summary?.usage.last_30_days ?? null);
const shares = $derived(period ? usageModelShares(period.agents) : []);
const modelCount = $derived(new Set(shares.map((share) => share.model)).size);
</script>

<svelte:head>
  <title>Models · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

<PageHeader>
  {#snippet eyebrow()}Models · Last 30 days{/snippet}
  {#if !period}
    Loading models…
  {:else if modelCount === 0}
    No model ran in the last 30 days.
  {:else}
    <b>{modelCount} {modelCount === 1 ? "model" : "models"}</b> ran
    <b>{formatCount(period.totals.total_tokens)} tokens</b> in the last 30 days, most of them
    on <b>{usageModelDisplayName(shares[0]?.model ?? "")}</b>.
  {/if}
</PageHeader>

{#if store.loadError}
  <RetryNotice
    message={store.loadError.message}
    actionLabel={accountNoticeActionLabel(store.loadError)}
    onRetry={accountNoticeRetry(store.loadError, () => void store.refresh())}
  />
{/if}

<PageSection id="models-breakdown-title" title="By agent and model">
  {#if !period}
    {#if !store.loadError}
      <LoadingBlock lines={4} label="Loading models" />
    {/if}
  {:else}
    <UsageBreakdown {period} />
  {/if}
</PageSection>
