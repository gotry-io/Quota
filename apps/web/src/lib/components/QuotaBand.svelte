<script lang="ts">
import { type AccountSummaryRead, providerDisplayName } from "@gotry-io/quota-protocol";
import { meterTone } from "$lib/account-overview";
import QuotaRing from "$lib/components/QuotaRing.svelte";
import { quotaBandItem } from "$lib/quota-band";
import { QUOTA_PATH, subscriptionPath } from "$lib/routes";

/**
 * One row under the header on every account page, so remaining quota stays in view while the
 * page itself is about Usage. One item per subscription, each linking to its own page.
 */
let {
  subscriptions,
  selectors,
  now,
}: {
  subscriptions: AccountSummaryRead["subscriptions"];
  selectors: Record<string, string>;
  now: Date;
} = $props();
</script>

<nav class="quota-band" aria-label="Remaining quota">
  <div class="wrap quota-band-row">
    {#each subscriptions as subscription (subscription.key)}
      {@const item = quotaBandItem(subscription, now)}
      {@const sel = selectors[subscription.key]}
      {@const tone = item.kind === "percent" ? meterTone(item.remaining) : null}
      <svelte:element
        this={sel ? "a" : "span"}
        class="quota-band-item"
        class:quota-band-warn={tone === "warn" || item.kind === "status"}
        class:quota-band-critical={tone === "critical"}
        href={sel ? subscriptionPath(sel) : undefined}
        data-provider={subscription.provider}
      >
        {#if item.kind === "percent"}
          <QuotaRing remaining={item.remaining} />
        {:else if item.kind === "status"}
          <QuotaRing remaining={0} />
        {/if}
        <span>{providerDisplayName(subscription.provider)}</span>
        {#if item.kind === "percent"}
          <b>{item.text}</b>
          <span>{item.window}</span>
        {:else if item.kind === "status"}
          <b>{item.word}</b>
        {:else if item.kind === "balance"}
          <b>{item.amount}</b>
        {:else}
          <b>—</b>
        {/if}
      </svelte:element>
    {/each}
    <a class="quota-band-more" href={QUOTA_PATH}>Quota →</a>
  </div>
</nav>

<style>
.quota-band {
  border-bottom: 1px solid var(--hairline);
}

.quota-band-row {
  display: flex;
  gap: 4px 22px;
  align-items: center;
  padding-block: 10px;
  overflow-x: auto;
  font-size: 13px;
  scrollbar-width: none;
}

.quota-band-row::-webkit-scrollbar {
  display: none;
}

.quota-band-item,
.quota-band-more {
  display: inline-flex;
  flex: none;
  gap: 7px;
  align-items: center;
  color: var(--body);
  text-decoration: none;
  white-space: nowrap;
}

.quota-band-item b {
  color: var(--ink);
  font-variant-numeric: tabular-nums;
  font-weight: 600;
}

a.quota-band-item:hover span {
  color: var(--ink);
}

.quota-band-warn b {
  color: var(--quota-warning);
}

.quota-band-critical b {
  color: var(--quota-critical);
}

.quota-band-more {
  margin-left: auto;
  font-weight: 500;
}

.quota-band-more:hover {
  color: var(--ink);
}
</style>
