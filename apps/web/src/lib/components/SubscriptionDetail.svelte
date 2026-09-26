<script lang="ts">
import { observedSnapshotStatus } from "@gotry-io/quota-model";
import { type AccountSummaryRead, providerDisplayName } from "@gotry-io/quota-protocol";
import {
  type AccountError,
  accountNoticeActionLabel,
  accountNoticeRetry,
} from "$lib/account-errors";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import PageHeader from "$lib/components/PageHeader.svelte";
import PageSection from "$lib/components/PageSection.svelte";
import ProviderMark from "$lib/components/ProviderMark.svelte";
import QuotaWindows from "$lib/components/QuotaWindows.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import { formatQuotaRemaining, observationFreshnessCopy } from "$lib/format";
import { planDisplayName, QUOTA_PATH } from "$lib/routes";

type Subscription = AccountSummaryRead["subscriptions"][number];
type Source = Subscription["sources"][number];
type Snapshot = Subscription["snapshot"];

let {
  sel,
  summary,
  loadError,
  subscriptionSelectors,
  onRetry,
  now = new Date(),
}: {
  sel: string;
  summary: AccountSummaryRead | null;
  loadError: AccountError | null;
  subscriptionSelectors: Record<string, string>;
  onRetry: () => void;
  now?: Date;
} = $props();

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

{#if !subscription}
  <PageHeader id="subscription-title">
    {#snippet eyebrow()}<a href={QUOTA_PATH}>Quota</a>{/snippet}
    Subscription
    {#snippet controls()}<a class="pill" href={QUOTA_PATH}>← Quota</a>{/snippet}
  </PageHeader>
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
  {:else}
    <p class="empty-state">This subscription is no longer reported.</p>
  {/if}
{:else}
  {@const snapshot = subscription.snapshot}
  {@const quotaStatus = observedSnapshotStatus(snapshot, now)}
  {@const plan = planDisplayName(snapshot.account.plan)}
  {@const name = providerDisplayName(subscription.provider)}
  <PageHeader id="subscription-title">
    {#snippet eyebrow()}<a href={QUOTA_PATH}>Quota</a> <span>/</span> <span>{name}</span>{/snippet}
    <b>{name}</b>
    {#snippet controls()}<a class="pill" href={QUOTA_PATH}>← Quota</a>{/snippet}
    {#snippet meta()}
      <ProviderMark provider={subscription.provider} />
      {#if snapshot.account.label}
        <span>{snapshot.account.label}</span>
      {/if}
      {#if plan}
        <span class="tag">{plan}</span>
      {/if}
      <span class="subscription-freshness"
        >{observationFreshnessCopy(quotaStatus, snapshot.observed_at, now)}</span
      >
    {/snippet}
  </PageHeader>
  {#if loadError}
    <RetryNotice
      message={loadError.message}
      actionLabel={accountNoticeActionLabel(loadError)}
      onRetry={accountNoticeRetry(loadError, onRetry)}
    />
  {/if}
  <PageSection id="subscription-windows-title" title="Windows">
    <QuotaWindows
      windows={snapshot.windows}
      provider={subscription.provider}
      {now}
      showPaceDetail={true}
    />
  </PageSection>
  <PageSection id="subscription-sources-title" title="Readings">
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
              {" · "}<span class="tag good">Reporting</span>{/if}
          </li>
        {/each}
      </ul>
    {/if}
  </PageSection>
{/if}
