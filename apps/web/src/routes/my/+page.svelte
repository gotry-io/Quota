<script lang="ts">
import { observedSnapshotStatus } from "@gotry-io/quota-model";
import type { AccountSummaryRead } from "@gotry-io/quota-protocol";
import { providerDisplayName } from "@gotry-io/quota-protocol";
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import { devicesSummaryLine, subscriptionCardMeta, topUsageModel } from "$lib/account-overview";
import { getAccountStore } from "$lib/account-store.svelte.ts";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import ProviderMark from "$lib/components/ProviderMark.svelte";
import QuotaWindows from "$lib/components/QuotaWindows.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import { costBasisLabel, formatCost, formatCount, observationFreshnessCopy } from "$lib/format";
import { DEVICES_PATH, planDisplayName, subscriptionPath, USAGE_PATH } from "$lib/routes";

const store = getAccountStore();
const now = $derived(store.now);
let today = $derived(store.summary?.usage.today ?? null);
let topModel = $derived(topUsageModel(today));
let deviceNames = $derived(
  new Map(store.summary?.devices.map((device) => [device.id, device.display_name]) ?? []),
);

function deviceName(deviceId: string): string {
  return deviceNames.get(deviceId) ?? "Device";
}

function reportingDevice(subscription: AccountSummaryRead["subscriptions"][number]): string {
  const selected = subscription.sources.find(
    (source) => source.observed_at === subscription.snapshot.observed_at,
  );
  return deviceName(selected?.device_id ?? "");
}

function cardMeta(subscription: AccountSummaryRead["subscriptions"][number]): string {
  const snapshot = subscription.snapshot;
  const quotaStatus = observedSnapshotStatus(snapshot, now);
  const device = reportingDevice(subscription);
  if (quotaStatus === "available") {
    return subscriptionCardMeta(device, snapshot.observed_at, now);
  }
  return `${device} · ${observationFreshnessCopy(quotaStatus, snapshot.observed_at, now)}`;
}
</script>

<svelte:head>
  <title>Account · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

{#if store.loadError}
  <RetryNotice
    message={store.loadError.message}
    actionLabel={accountNoticeActionLabel(store.loadError)}
    onRetry={accountNoticeRetry(store.loadError, () => void store.refresh())}
  />
{/if}

<section class="overview-section" aria-labelledby="quota-title">
  <h2 id="quota-title">Subscriptions</h2>
  {#if !store.summary}
    {#if !store.loadError}
      <LoadingBlock lines={4} label="Loading subscriptions" />
    {/if}
  {:else}
    <div id="quota-list" class="quota-grid">
      {#if store.summary.subscriptions.length === 0}
        <p class="empty-state">No quota snapshots yet. Sign in from QuotaBar to add this Mac.</p>
      {:else}
        {#each store.summary.subscriptions as subscription (subscription.key)}
          {@const snapshot = subscription.snapshot}
          {@const sel = store.subscriptionSelectors[subscription.key]}
          {@const plan = planDisplayName(snapshot.account.plan)}
          <article class="quota-card">
            {#snippet card()}
              <div class="quota-card-heading">
                <ProviderMark provider={subscription.provider} />
                <div class="quota-card-identity">
                  <p class="quota-card-provider">{providerDisplayName(subscription.provider)}</p>
                  <p class="quota-card-account">{snapshot.account.label || "Account"}</p>
                </div>
                {#if plan}
                  <span class="status-pill">{plan}</span>
                {/if}
              </div>
              <QuotaWindows windows={snapshot.windows} provider={subscription.provider} {now} />
              <p class="quota-card-meta">{cardMeta(subscription)}</p>
            {/snippet}
            {#if sel}
              <a class="quota-card-main" href={subscriptionPath(sel)}>{@render card()}</a>
            {:else}
              <div class="quota-card-main">{@render card()}</div>
            {/if}
          </article>
        {/each}
      {/if}
    </div>
  {/if}
</section>

<section class="overview-section" aria-labelledby="today-title">
  <h2 id="today-title">Today</h2>
  {#if !today}
    {#if !store.loadError}
      <LoadingBlock lines={2} label="Loading today" />
    {/if}
  {:else}
    <a class="today-strip" href={`${USAGE_PATH}?period=today`} aria-labelledby="today-title">
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
</section>

{#if store.summary && (store.summary.devices.length > 0 || store.summary.subscriptions.length > 0)}
  <section class="overview-section overview-devices">
    <a class="devices-strip" href={DEVICES_PATH}>{devicesSummaryLine(store.summary.devices, now)}</a>
  </section>
{/if}
