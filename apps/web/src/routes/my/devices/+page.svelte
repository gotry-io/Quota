<script lang="ts">
import type { AccountDeviceRead } from "@gotry-io/quota-protocol";
import { page } from "$app/state";
import { deleteDevice } from "$lib/account-client";
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import { isPaidSyncStatus } from "$lib/account-overview";
import { getAccountStore } from "$lib/account-store.svelte.ts";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import PlatformIcon from "$lib/components/PlatformIcon.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import { deviceActivity, sortDevicesByLastSeen } from "$lib/device-activity";
import { relativeAge } from "$lib/format";

const store = getAccountStore();
const now = $derived(store.now);
const devices = $derived(store.summary ? sortDevicesByLastSeen(store.summary.devices) : []);
const subscribed = $derived(
  store.summary ? isPaidSyncStatus(store.summary.entitlement.status) : true,
);

function instantCopy(value: string | null): string {
  return value ? relativeAge(value, now) : "—";
}

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

<section class="overview-section" aria-labelledby="dashboard-title">
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
    <div id="device-list">
      {#if devices.length === 0}
        <p class="empty-state">No devices yet. Sign in from QuotaBar to add this Mac.</p>
      {:else}
        <div class="table-wrap device-table-wrap">
          <table class="device-table">
            <caption class="visually-hidden">Devices</caption>
            <thead>
              <tr>
                <th scope="col">Name</th>
                <th scope="col">Platform</th>
                <th scope="col">Status</th>
                <th scope="col">Last contact</th>
                <th scope="col"><span class="visually-hidden">Delete</span></th>
              </tr>
            </thead>
            <tbody>
              {#each devices as device (device.id)}
                {@const activity = deviceActivity(device, now, { subscribed })}
                <tr>
                  <th scope="row">{device.display_name}</th>
                  <td><PlatformIcon platform={device.platform} /></td>
                  <td><span class="status-pill status-{activity.tone}">{activity.label}</span></td>
                  <td>{instantCopy(activity.since)}</td>
                  <td>
                    <button
                      class="text-button danger-button"
                      type="button"
                      aria-label="Delete {device.display_name} and data"
                      onclick={(event) => void onDeleteDevice(device, event)}>Delete</button
                    >
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
        <ul class="device-card-list">
          {#each devices as device (device.id)}
            {@const activity = deviceActivity(device, now, { subscribed })}
            <li class="device-card">
              <div class="device-card-head">
                <strong>{device.display_name}</strong>
                <PlatformIcon platform={device.platform} />
              </div>
              <dl>
                <div>
                  <dt>Status</dt>
                  <dd><span class="status-pill status-{activity.tone}">{activity.label}</span></dd>
                </div>
                <div>
                  <dt>Last contact</dt>
                  <dd>{instantCopy(activity.since)}</dd>
                </div>
              </dl>
              <button
                class="text-button danger-button"
                type="button"
                aria-label="Delete {device.display_name} and data"
                onclick={(event) => void onDeleteDevice(device, event)}>Delete</button
              >
            </li>
          {/each}
        </ul>
      {/if}
    </div>
  {/if}
</section>
