<script lang="ts">
import type { AccountDeviceRead } from "@gotry-io/quota-protocol";
import { page } from "$app/state";
import { deleteDevice } from "$lib/account-client";
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import { devicesSummaryLine } from "$lib/account-overview";
import { getAccountStore } from "$lib/account-store.svelte.ts";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import PageHeader from "$lib/components/PageHeader.svelte";
import PageSection from "$lib/components/PageSection.svelte";
import PlatformIcon from "$lib/components/PlatformIcon.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import { deviceActivity, sortDevicesByLastSeen } from "$lib/device-activity";
import { relativeAge } from "$lib/format";

const store = getAccountStore();
const now = $derived(store.now);
const devices = $derived(store.summary ? sortDevicesByLastSeen(store.summary.devices) : []);
const reporting = $derived(
  devices.filter((device) => deviceActivity(device, now).tone !== "unavailable").length,
);
/** The one row asking whether to delete, so a second Delete… closes the first question. */
let confirming = $state<string | null>(null);
let deleting = $state<string | null>(null);

function instantCopy(value: string | null): string {
  return value ? relativeAge(value, now) : "—";
}

async function onDeleteDevice(device: AccountDeviceRead): Promise<void> {
  deleting = device.id;
  const outcome = await deleteDevice(device.id, page.url.pathname);
  deleting = null;
  if (outcome !== "ok") {
    store.setError(outcome);
    return;
  }
  confirming = null;
  await store.refresh();
}
</script>

<svelte:head>
  <title>Devices · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

<PageHeader>
  {#snippet eyebrow()}Devices{/snippet}
  {#if !store.summary}
    Loading devices…
  {:else if devices.length === 0}
    No devices yet.
  {:else}
    <b>{reporting} of {devices.length}</b>
    {devices.length === 1 ? "device is" : "devices are"} reporting.
  {/if}
  {#snippet meta()}
    {#if store.summary && devices.length > 0}
      <span class="dashboard-status">{devicesSummaryLine(store.summary.devices, now)}</span>
    {/if}
  {/snippet}
</PageHeader>

{#if store.loadError}
  <RetryNotice
    message={store.loadError.message}
    actionLabel={accountNoticeActionLabel(store.loadError)}
    onRetry={accountNoticeRetry(store.loadError, () => void store.refresh())}
  />
{/if}

<PageSection id="device-list-title" title="Devices" titleHidden>
  {#if !store.summary}
    {#if !store.loadError}
      <LoadingBlock lines={3} label="Loading devices" />
    {/if}
  {:else}
    <div id="device-list">
      {#if devices.length === 0}
        <p class="empty-state">No devices yet. Sign in from QuotaBar to add this Mac.</p>
      {:else}
        <div class="table-scroll">
          <table class="data-table">
            <caption class="visually-hidden">Devices</caption>
            <thead>
              <tr>
                <th scope="col">Name</th>
                <th scope="col">Status</th>
                <th scope="col">Last contact</th>
                <th scope="col">Platform</th>
                <th scope="col"><span class="visually-hidden">Delete</span></th>
              </tr>
            </thead>
            <tbody>
              {#each devices as device (device.id)}
                {@const activity = deviceActivity(device, now)}
                <tr>
                  <th scope="row">{device.display_name}</th>
                  <td><span class="status status-{activity.tone}">{activity.label}</span></td>
                  <td class="data-table-quiet">{instantCopy(activity.since)}</td>
                  <td><PlatformIcon platform={device.platform} /></td>
                  <td class="data-table-action">
                    {#if confirming === device.id}
                      <span class="data-table-quiet confirm-copy"
                        >Removes it and its Quota and Usage data</span
                      >
                      <button class="pill sm" type="button" onclick={() => (confirming = null)}
                        >Cancel</button
                      >
                      <button
                        class="pill sm danger"
                        type="button"
                        disabled={deleting === device.id}
                        aria-label="Delete {device.display_name} and data"
                        onclick={() => void onDeleteDevice(device)}>Delete</button
                      >
                    {:else}
                      <button
                        class="pill sm danger"
                        type="button"
                        aria-label="Delete {device.display_name}…"
                        onclick={() => (confirming = device.id)}>Delete…</button
                      >
                    {/if}
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
        <p class="footnote">
          Active under 30 minutes · Idle up to a day · Not reporting beyond that. A sleeping Mac is
          Idle, not broken.
        </p>
      {/if}
    </div>
  {/if}
</PageSection>

<style>
.confirm-copy {
  margin-right: 4px;
  font-size: 12px;
}
</style>
