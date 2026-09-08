<script lang="ts">
import type { AccountDeviceRead } from "@gotry-io/quota-protocol";
import { deviceActivity } from "$lib/device-activity";
import { lastReadingCopy } from "$lib/format";

let {
  devices,
  now = new Date(),
}: {
  devices: readonly Pick<
    AccountDeviceRead,
    "id" | "display_name" | "last_seen_at" | "last_observed_at"
  >[];
  now?: Date;
} = $props();
</script>

{#if devices.length === 0}
  <p class="empty-state">No devices yet. Sign in from QuotaBar to add this Mac.</p>
{:else}
  <ul class="device-summary-list">
    {#each devices as device (device.id)}
      {@const activity = deviceActivity(device, now)}
      <li>{device.display_name} · {activity.label} · {lastReadingCopy(activity.since, now)}</li>
    {/each}
  </ul>
{/if}
