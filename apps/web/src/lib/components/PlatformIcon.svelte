<script lang="ts">
import { platformDisplayName } from "@gotry-io/quota-protocol";
import { platformIconKind } from "$lib/device-activity";

let { platform }: { platform: string } = $props();

const kind = $derived(platformIconKind(platform));
const label = $derived(platformDisplayName(platform));
</script>

{#if kind === "mac"}
  <svg class="platform-icon" viewBox="0 0 24 24" role="img" aria-label={label}>
    <rect
      x="3.25"
      y="4.25"
      width="17.5"
      height="11.5"
      rx="1.6"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
    />
    <path
      d="M2.5 18.5h19"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
    />
  </svg>
{:else}
  <svg class="platform-icon" viewBox="0 0 24 24" role="img" aria-label={label}>
    <rect
      x="5.25"
      y="5.25"
      width="13.5"
      height="13.5"
      rx="2.4"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
    />
    <circle cx="12" cy="12" r="1.4" fill="currentColor" />
  </svg>
{/if}
