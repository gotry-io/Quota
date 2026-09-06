<script lang="ts">
import { page } from "$app/state";
import { accountStatusLine, devicesSummaryLine, isPaidSyncStatus } from "$lib/account-overview";
import { createAccountStore, setAccountStore } from "$lib/account-store.svelte.ts";
import {
  accountPageTitle,
  isDevicesPath,
  isSettingsPath,
  isSubscriptionPath,
  isUsagePath,
} from "$lib/routes";

let { children } = $props();

const store = createAccountStore();
setAccountStore(store);

const title = $derived(accountPageTitle(page.url.pathname));
const showHeading = $derived(
  !isSubscriptionPath(page.url.pathname) && !isUsagePath(page.url.pathname),
);
const headingId = $derived(
  isSubscriptionPath(page.url.pathname) ? "subscription-title" : "dashboard-title",
);
const now = $derived(store.now);
const status = $derived.by(() => {
  if (!store.summary) return null;
  const path = page.url.pathname;
  if (isUsagePath(path) || isSettingsPath(path) || isSubscriptionPath(path)) return null;
  if (isDevicesPath(path)) {
    return devicesSummaryLine(store.summary.devices, now, {
      subscribed: isPaidSyncStatus(store.summary.entitlement.status),
    });
  }
  return accountStatusLine(store.summary, now);
});

$effect(() => {
  void page.url.pathname;
  void store.ensureSummary();
});

$effect(() => {
  return store.startClock();
});
</script>

<section id="dashboard-view" class="dashboard" aria-labelledby={headingId}>
  {#if showHeading}
    <header class="dashboard-page-heading">
      <h1 id="dashboard-title">{title}</h1>
      {#if status}
        <p class="dashboard-status">{status}</p>
      {/if}
    </header>
  {/if}
  {@render children()}
</section>
