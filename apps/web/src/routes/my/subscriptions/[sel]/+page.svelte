<script lang="ts">
import { remainingPercent } from "@gotry-io/quota-model";
import { formatWindowTitle } from "@gotry-io/quota-model";
import { page } from "$app/state";
import { getAccountStore, quotaHistoryKey } from "$lib/account-store.svelte.ts";
import SubscriptionDetail from "$lib/components/SubscriptionDetail.svelte";
import { modelColors } from "$lib/model-colors";
import { fetchProviderStatus } from "$lib/provider-status";
import { isCurrent, windowAttribution, windowAttributionRange } from "$lib/quota-overview";

const store = getAccountStore();
const sel = $derived(page.params.sel ?? "");
const subscription = $derived(
  store.summary?.subscriptions.find((item) => store.subscriptionSelectors[item.key] === sel),
);
/** Account history exists only for a subscription whose fingerprint means the same everywhere. */
const historyQuery = $derived.by(() => {
  const snapshot = subscription?.snapshot;
  if (!snapshot || snapshot.account.fingerprint_scope !== "global") return null;
  const starts = snapshot.windows
    .filter((window) => window.resets_at && window.duration_seconds)
    .map((window) => Date.parse(window.resets_at ?? "") - (window.duration_seconds ?? 0) * 1_000);
  if (starts.length === 0) return null;
  return {
    provider: subscription.provider,
    fingerprint: snapshot.account.fingerprint,
    since: new Date(Math.min(...starts)).toISOString().replace(/\.\d+Z$/, "Z"),
  };
});
/** The window at least a day long with the least left, which the estimate is about. */
const attributed = $derived.by(() => {
  if (!subscription || !isCurrent(subscription, store.now)) return null;
  let best: { title: string; range: { from: string; to: string }; remaining: number } | null = null;
  for (const window of subscription.snapshot.windows) {
    const range = windowAttributionRange(window, store.now);
    if (!range) continue;
    const remaining = remainingPercent(window.used_percent);
    if (best === null || remaining < best.remaining) {
      best = { title: formatWindowTitle(window.title, window), range, remaining };
    }
  }
  return best;
});
const attributionAgents = $derived(
  attributed ? store.periodFor(attributed.range, { breakdown: true })?.data?.agents : undefined,
);
let providerStatus = $state<{ indicator: string; description: string } | null>(null);

$effect(() => {
  if (historyQuery) void store.ensureQuotaHistory(historyQuery);
});

$effect(() => {
  if (attributed) void store.ensurePeriod(attributed.range, { breakdown: true });
});

$effect(() => {
  const provider = subscription?.provider;
  if (!provider) return;
  let cancelled = false;
  void fetchProviderStatus().then((rows) => {
    if (cancelled) return;
    const row = rows.find((item) => item.id === provider);
    providerStatus = row ?? null;
  });
  return () => {
    cancelled = true;
  };
});
</script>

<SubscriptionDetail
  {sel}
  summary={store.summary}
  loadError={store.loadError}
  subscriptionSelectors={store.subscriptionSelectors}
  now={store.now}
  onRetry={() => void store.refresh()}
  history={historyQuery ? (store.quotaHistory[quotaHistoryKey(historyQuery)]?.data ?? null) : null}
  attribution={attributed && subscription
    ? {
        title: attributed.title,
        shares: attributionAgents ? windowAttribution(attributionAgents, subscription.provider) : null,
      }
    : null}
  colors={modelColors(store.summary?.usage.all.agents ?? [])}
  {providerStatus}
/>
