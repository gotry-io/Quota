<script lang="ts">
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import { getAccountStore } from "$lib/account-store.svelte.ts";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import PageHeader from "$lib/components/PageHeader.svelte";
import PageSection from "$lib/components/PageSection.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import { costBasisLabel, formatCost, formatCount } from "$lib/format";
import { cacheHitLabel, cacheSavedLabel } from "$lib/usage-metrics";

const store = getAccountStore();
const week = $derived(store.summary?.usage.last_7_days ?? null);
</script>

<svelte:head>
  <title>Recap · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

<PageHeader>
  {#snippet eyebrow()}Recap · Last 7 days{/snippet}
  {#if !week}
    Loading your week…
  {:else}
    Your week: <b>{formatCount(week.totals.total_tokens)} tokens</b> over
    <b>{formatCount(week.totals.messages)} messages</b>. Private to you.
  {/if}
</PageHeader>

{#if store.loadError}
  <RetryNotice
    message={store.loadError.message}
    actionLabel={accountNoticeActionLabel(store.loadError)}
    onRetry={accountNoticeRetry(store.loadError, () => void store.refresh())}
  />
{/if}

<PageSection id="recap-totals-title" title="Last 7 days">
  {#if !week}
    {#if !store.loadError}
      <LoadingBlock lines={2} label="Loading your week" />
    {/if}
  {:else}
    <dl class="figures">
      <div>
        <dt>Tokens</dt>
        <dd>{formatCount(week.totals.total_tokens)}</dd>
        <dd class="figures-note">
          {formatCount(week.totals.input_tokens)} in · {formatCount(week.totals.output_tokens)} out
        </dd>
      </div>
      <div>
        <dt>Messages</dt>
        <dd>{formatCount(week.totals.messages)}</dd>
      </div>
      <div>
        <dt>API-equivalent cost</dt>
        <dd>{formatCost(week.cost)}</dd>
        <dd class="figures-note">{costBasisLabel(week.cost)}</dd>
      </div>
      <div>
        <dt>From cache</dt>
        <dd>{cacheHitLabel(week.totals) ?? "—"}</dd>
        <dd class="figures-note">{cacheSavedLabel(week.cache_saved) ?? "Nothing priced to compare"}</dd>
      </div>
    </dl>
  {/if}
</PageSection>

<p class="footnote">Nothing here ranks you against anyone.</p>
