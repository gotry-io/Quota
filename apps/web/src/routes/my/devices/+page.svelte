<script lang="ts">
import type { AccountDeviceRead } from "@gotry-io/quota-protocol";
import { platformDisplayName } from "@gotry-io/quota-protocol";
import { page } from "$app/state";
import { deleteDevice } from "$lib/account-client";
import { getAccountStore } from "$lib/account-store.svelte.ts";
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import { deviceActivity } from "$lib/device-activity";
import { lastReadingCopy } from "$lib/format";

const store = getAccountStore();

async function onDeleteDevice(device: AccountDeviceRead, event: Event): Promise<void> {
  if (!window.confirm(`Delete ${device.display_name} and all of its Quota and Usage data?`)) {
    return;
  }
  const button = event.currentTarget;
  if (button instanceof HTMLButtonElement) button.disabled = true;
  const outcome = await deleteDevice(device.id, page.url.pathname);
  if (outcome !== "ok") {
    if (button instanceof HTMLButtonElement) button.disabled = false;
    store.setError(outcome);
    return;
  }
  await store.refresh();
}
</script>

<svelte:head>
  <title>Devices · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

<section class="dashboard-section" aria-labelledby="devices-title">
  <div class="dashboard-section-heading">
    <div>
      <p class="eyebrow">Installations</p>
      <h2 id="devices-title">Devices</h2>
    </div>
    <span id="device-count" class="count-pill"
      >{store.summary ? store.summary.devices.length : ""}</span
    >
  </div>
  {#if store.loadError}
    <RetryNotice
      message={store.loadError.message}
      actionLabel={accountNoticeActionLabel(store.loadError)}
      onRetry={accountNoticeRetry(store.loadError, () => void store.refresh())}
    />
  {/if}
  {#if !store.summary}
    {#if !store.loadError}
      <LoadingBlock lines={3} label="Loading devices" />
    {/if}
  {:else}
    <div id="device-list" class="device-grid">
      {#if store.summary.devices.length === 0}
        <p class="empty-state">No devices yet. Sign in from QuotaBar to add this Mac.</p>
      {:else}
        {#each store.summary.devices as device (device.id)}
          {@const activity = deviceActivity(device)}
          <article class="device-card">
            <div class="device-card-heading">
              <h3>{device.display_name}</h3>
              <span class="status-pill status-{activity.tone}">{activity.label}</span>
            </div>
            <p>
              {platformDisplayName(device.platform)} · {lastReadingCopy(activity.since)}
            </p>
            <button
              class="text-button danger-button"
              type="button"
              onclick={(event) => void onDeleteDevice(device, event)}
              >Delete device and data</button
            >
          </article>
        {/each}
      {/if}
    </div>
  {/if}
</section>
