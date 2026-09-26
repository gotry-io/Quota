<script lang="ts">
import { observedSnapshotStatus } from "@gotry-io/quota-model";
import { type AccountSummaryRead, providerDisplayName } from "@gotry-io/quota-protocol";
import { subscriptionCardMeta } from "$lib/account-overview";
import ProviderMark from "$lib/components/ProviderMark.svelte";
import QuotaWindows from "$lib/components/QuotaWindows.svelte";
import { observationFreshnessCopy } from "$lib/format";
import { fetchProviderStatus, showsProviderStatusDot } from "$lib/provider-status";
import { planDisplayName, subscriptionPath } from "$lib/routes";

type Subscription = AccountSummaryRead["subscriptions"][number];

/** One card per subscription, each linking to its own page once its selector is known. */
let {
  summary,
  selectors,
  now,
}: {
  summary: AccountSummaryRead;
  selectors: Record<string, string>;
  now: Date;
} = $props();

const deviceNames = $derived(
  new Map(summary.devices.map((device) => [device.id, device.display_name])),
);
let providerStatus = $state<Map<string, { indicator: string; description: string }>>(new Map());

$effect(() => {
  let cancelled = false;
  void fetchProviderStatus().then((rows) => {
    if (cancelled) return;
    providerStatus = new Map(rows.map((row) => [row.id, row]));
  });
  return () => {
    cancelled = true;
  };
});

function reportingDevice(subscription: Subscription): string {
  const selected = subscription.sources.find(
    (source) => source.observed_at === subscription.snapshot.observed_at,
  );
  return deviceNames.get(selected?.device_id ?? "") ?? "Device";
}

function cardMeta(subscription: Subscription): string {
  const snapshot = subscription.snapshot;
  const quotaStatus = observedSnapshotStatus(snapshot, now);
  const device = reportingDevice(subscription);
  if (quotaStatus === "available") {
    return subscriptionCardMeta(device, snapshot.observed_at, now);
  }
  return `${device} · ${observationFreshnessCopy(quotaStatus, snapshot.observed_at, now)}`;
}
</script>

<div id="quota-list" class="quota-grid">
  {#if summary.subscriptions.length === 0}
    <p class="empty-state">No quota snapshots yet. Sign in from QuotaBar to add this Mac.</p>
  {:else}
    {#each summary.subscriptions as subscription (subscription.key)}
      {@const snapshot = subscription.snapshot}
      {@const sel = selectors[subscription.key]}
      {@const plan = planDisplayName(snapshot.account.plan)}
      {@const status = providerStatus.get(subscription.provider)}
      <article class="quota-card">
        {#snippet card()}
          <div class="quota-card-heading">
            <ProviderMark provider={subscription.provider} />
            <div class="quota-card-identity">
              <p class="quota-card-provider">
                {providerDisplayName(subscription.provider)}
                {#if status && showsProviderStatusDot(status.indicator)}
                  <span
                    class="provider-status-dot provider-status-dot-{status.indicator}"
                    title={status.description}
                    aria-hidden="true"
                  ></span>
                {/if}
              </p>
              <p class="quota-card-account">{snapshot.account.label || "Account"}</p>
            </div>
            {#if plan}
              <span class="tag">{plan}</span>
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
