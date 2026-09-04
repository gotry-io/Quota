<script lang="ts">
import { platformDisplayName } from "@gotry-io/quota-protocol";
import { platformIconKind } from "$lib/device-activity";

let { platform }: { platform: string } = $props();

const kind = $derived(platformIconKind(platform));
const label = $derived(platformDisplayName(platform));
</script>

{#if kind === "iphone"}
  <svg class="platform-icon" viewBox="0 0 24 24" role="img" aria-label={label}>
    <rect
      x="7.25"
      y="2.25"
      width="9.5"
      height="19.5"
      rx="2.2"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
    />
    <path
      d="M10 19.4h4"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
    />
  </svg>
{:else}
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
{/if}
