<script lang="ts">
import { observedSnapshotStatus } from "@gotry-io/quota-model";
import { type AccountSummaryRead, providerDisplayName } from "@gotry-io/quota-protocol";
import {
  type AccountError,
  accountNoticeActionLabel,
  accountNoticeRetry,
} from "$lib/account-errors";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import QuotaWindows from "$lib/components/QuotaWindows.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import { formatQuotaRemaining, observationFreshnessCopy } from "$lib/format";
import { DASHBOARD_PATH, planDisplayName } from "$lib/routes";

type Subscription = AccountSummaryRead["subscriptions"][number];
type Source = Subscription["sources"][number];
type Snapshot = Subscription["snapshot"];

let {
  sel,
  summary,
  loadError,
  subscriptionSelectors,
  onRetry,
}: {
  sel: string;
  summary: AccountSummaryRead | null;
  loadError: AccountError | null;
  subscriptionSelectors: Record<string, string>;
  onRetry: () => void;
} = $props();

let nowMs = $state(Date.now());
const now = $derived(new Date(nowMs));

$effect(() => {
  const timer = setInterval(() => {
    nowMs = Date.now();
  }, 60_000);
  return () => clearInterval(timer);
});

const subscription = $derived(
  summary?.subscriptions.find((item) => subscriptionSelectors[item.key] === sel),
);
const title = $derived(
  subscription ? `${providerDisplayName(subscription.provider)} · Quota` : "Account · Quota",
);
const deviceNames = $derived(
  new Map(summary?.devices.map((device) => [device.id, device.display_name]) ?? []),
);
const sources = $derived(
  subscription
    ? [...subscription.sources].sort(
        (left, right) => Date.parse(right.observed_at) - Date.parse(left.observed_at),
      )
    : [],
);

function deviceName(deviceId: string): string {
  return deviceNames.get(deviceId) ?? "Device";
}

function sourceSnapshot(item: Subscription, source: Source): Snapshot | undefined {
  if (source.snapshot) return source.snapshot;
  if (source.observed_at === item.snapshot.observed_at) return item.snapshot;
  return undefined;
}

function primaryRemaining(snapshot: Snapshot | undefined): string | undefined {
  const window = snapshot?.windows.find((item) => item.primary_cadence) ?? snapshot?.windows[0];
  return window ? formatQuotaRemaining(window) : undefined;
}

function sourceFreshness(snapshot: Snapshot | undefined, observedAt: string): string {
  const status = snapshot ? observedSnapshotStatus(snapshot, now) : "available";
  return observationFreshnessCopy(status, observedAt, now);
}
</script>

<svelte:head>
  <title>{title}</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

<section class="dashboard-section" aria-labelledby="subscription-title">
  <p class="subscription-back">
    <a href={DASHBOARD_PATH}>← Overview</a>
  </p>
  <div class="dashboard-section-heading">
    <div>
      <p class="eyebrow">Subscription</p>
      <h2 id="subscription-title">
        {subscription ? providerDisplayName(subscription.provider) : "Subscription"}
      </h2>
      {#if subscription?.snapshot.account.label}
        <p class="subscription-label">{subscription.snapshot.account.label}</p>
      {/if}
    </div>
    {#if subscription}
      {@const plan = planDisplayName(subscription.snapshot.account.plan)}
      {#if plan}
        <span class="status-pill">{plan}</span>
      {/if}
    {/if}
  </div>
  {#if loadError}
    <RetryNotice
      message={loadError.message}
      actionLabel={accountNoticeActionLabel(loadError)}
      onRetry={accountNoticeRetry(loadError, onRetry)}
    />
  {/if}
  {#if !summary}
    {#if !loadError}
      <LoadingBlock lines={4} label="Loading subscription" />
    {/if}
  {:else if !subscription}
    <p class="empty-state">This subscription is no longer reported.</p>
  {:else}
    {@const snapshot = subscription.snapshot}
    {@const quotaStatus = observedSnapshotStatus(snapshot, now)}
    <p class="subscription-freshness">
      {observationFreshnessCopy(quotaStatus, snapshot.observed_at, now)}
    </p>
    <QuotaWindows windows={snapshot.windows} now={now} />
    <div class="subscription-sources">
      <h3 id="subscription-sources-title">Devices</h3>
      {#if sources.length === 0}
        <p class="empty-state">No devices reported this subscription.</p>
      {:else}
        <ul class="subscription-source-list" aria-labelledby="subscription-sources-title">
          {#each sources as source (`${source.device_id}:${source.observed_at}`)}
            {@const reading = sourceSnapshot(subscription, source)}
            {@const remaining = primaryRemaining(reading)}
            {@const reporting = source.observed_at === snapshot.observed_at}
            <li>
              {deviceName(source.device_id)}{#if remaining}
                {" · "}{remaining}{/if}{" · "}{sourceFreshness(reading, source.observed_at)}{#if reporting}
                {" · "}<strong>Reporting</strong>{/if}
            </li>
          {/each}
        </ul>
      {/if}
    </div>
  {/if}
</section>

