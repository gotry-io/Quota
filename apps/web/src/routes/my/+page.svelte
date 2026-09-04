<script lang="ts">
import type { AccountSummaryRead } from "@gotry-io/quota-protocol";
import { providerDisplayName } from "@gotry-io/quota-protocol";
import { observedSnapshotStatus } from "@gotry-io/quota-model";
import { getAccountDashboard } from "$lib/account-dashboard.svelte.ts";
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import DeviceSummary from "$lib/components/DeviceSummary.svelte";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import QuotaWindows from "$lib/components/QuotaWindows.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import { costBasisLabel, formatCost, formatCount, observationFreshnessCopy } from "$lib/format";
import { planDisplayName, subscriptionPath } from "$lib/routes";

const dashboard = getAccountDashboard();
let today = $derived(dashboard.summary?.usage.today ?? null);
let deviceNames = $derived(
  new Map(dashboard.summary?.devices.map((device) => [device.id, device.display_name]) ?? []),
);

function deviceName(deviceId: string): string {
  return deviceNames.get(deviceId) ?? "Device";
}

function otherReportingDevices(subscription: AccountSummaryRead["subscriptions"][number]): string {
  return subscription.sources
    .filter((source) => source.observed_at !== subscription.snapshot.observed_at)
    .map((source) => deviceName(source.device_id))
    .join(", ");
}

function reportingDevice(subscription: AccountSummaryRead["subscriptions"][number]): string {
  const selected = subscription.sources.find(
    (source) => source.observed_at === subscription.snapshot.observed_at,
  );
  return deviceName(selected?.device_id ?? "");
}
</script>

<svelte:head>
  <title>Account · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

<section class="dashboard-section" aria-labelledby="quota-title">
  <div class="dashboard-section-heading">
    <div>
      <p class="eyebrow">Plan limits</p>
      <h2 id="quota-title">Subscriptions</h2>
    </div>
  </div>
  {#if dashboard.loadError}
    <RetryNotice
      message={dashboard.loadError.message}
      actionLabel={accountNoticeActionLabel(dashboard.loadError)}
      onRetry={accountNoticeRetry(dashboard.loadError, () => void dashboard.loadSummary())}
    />
  {/if}
  {#if !dashboard.summary}
    {#if !dashboard.loadError}
      <LoadingBlock lines={4} label="Loading subscriptions" />
    {/if}
  {:else}
    <div id="quota-list" class="quota-grid">
      {#if dashboard.summary.subscriptions.length === 0}
        <p class="empty-state">No quota snapshots yet. Sign in from QuotaBar to add this Mac.</p>
      {:else}
        {#each dashboard.summary.subscriptions as subscription (subscription.key)}
          {@const snapshot = subscription.snapshot}
          {@const quotaStatus = observedSnapshotStatus(snapshot)}
          {@const alsoReporting = otherReportingDevices(subscription)}
          {@const sel = dashboard.subscriptionSelectors[subscription.key]}
          <article class="quota-card">
            {#snippet card()}
              <div class="quota-card-heading">
                <div class="quota-card-identity">
                  <p class="quota-card-provider">{providerDisplayName(subscription.provider)}</p>
                  <p class="quota-card-account">
                    {[snapshot.account.label, planDisplayName(snapshot.account.plan)]
                      .filter(Boolean)
                      .join(" · ") || "Account"}
                  </p>
                </div>
              </div>
              <QuotaWindows windows={snapshot.windows} provider={subscription.provider} />
              <p class="quota-card-meta">
                {reportingDevice(subscription)} · {observationFreshnessCopy(
                  quotaStatus,
                  snapshot.observed_at,
                )}
              </p>
              {#if alsoReporting}
                <p class="quota-card-meta">Also reporting: {alsoReporting}</p>
              {/if}
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

<section class="dashboard-section" aria-labelledby="today-title">
  <div class="dashboard-section-heading">
    <div>
      <p class="eyebrow">Usage</p>
      <h2 id="today-title">Today</h2>
    </div>
  </div>
  {#if dashboard.loadError}
    <RetryNotice
      message={dashboard.loadError.message}
      actionLabel={accountNoticeActionLabel(dashboard.loadError)}
      onRetry={accountNoticeRetry(dashboard.loadError, () => void dashboard.loadSummary())}
    />
  {/if}
  {#if !today}
    {#if !dashboard.loadError}
      <LoadingBlock lines={2} label="Loading today" />
    {/if}
  {:else}
    <div class="summary-grid">
      <article
        ><span>Tokens</span><strong
          >{formatCount(today.totals.total_tokens)}</strong
        ><small
          >{`${formatCount(today.totals.input_tokens)} in · ${formatCount(today.totals.output_tokens)} out`}</small
        ></article
      >
      <article
        ><span>API-equivalent cost</span><strong>{formatCost(today.cost)}</strong><small
          >{costBasisLabel(today.cost)}</small
        ></article
      >
    </div>
  {/if}
</section>

<section class="dashboard-section" aria-labelledby="devices-summary-title">
  <div class="dashboard-section-heading">
    <div>
      <p class="eyebrow">Installations</p>
      <h2 id="devices-summary-title">Devices</h2>
    </div>
    <span id="overview-device-count" class="count-pill"
      >{dashboard.summary ? dashboard.summary.devices.length : ""}</span
    >
  </div>
  {#if dashboard.loadError}
    <RetryNotice
      message={dashboard.loadError.message}
      actionLabel={accountNoticeActionLabel(dashboard.loadError)}
      onRetry={accountNoticeRetry(dashboard.loadError, () => void dashboard.loadSummary())}
    />
  {/if}
  {#if !dashboard.summary}
    {#if !dashboard.loadError}
      <LoadingBlock lines={3} label="Loading devices" />
    {/if}
  {:else}
    <DeviceSummary devices={dashboard.summary.devices} />
  {/if}
</section>
