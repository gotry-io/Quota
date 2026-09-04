<script lang="ts">
import { providerDisplayName } from "@gotry-io/quota-protocol";
import { providerMarkHue } from "$lib/account-overview";
import { providerMarkSrc } from "$lib/providers";

let { provider }: { provider: string } = $props();

let failed = $state(false);
const src = $derived(providerMarkSrc(provider));
const letter = $derived((providerDisplayName(provider).charAt(0) || "?").toUpperCase());
const hue = $derived(providerMarkHue(provider));
</script>

{#if src && !failed}
  <img
    class="provider-mark"
    src={src}
    alt=""
    width="28"
    height="28"
    onerror={() => {
      failed = true;
    }}
  />
{:else}
  <span class="provider-mark-fallback" style={`--mark-hue: ${hue}`} aria-hidden="true">{letter}</span>
{/if}
