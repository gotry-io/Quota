<script lang="ts">
import { meterTone } from "$lib/account-overview";

/**
 * Remaining quota drawn on the Quota mark's ring: the same centre and radius as the logo's outer
 * ring, a neutral track, and an arc from twelve o'clock clockwise in the remaining band's colour.
 *
 * Zero draws no arc at all, because a round cap on an empty dash is still a dot. The ring never
 * carries the number alone: at small sizes the text beside it does, and a `label` puts it in the
 * middle once the ring is large enough to hold it.
 */
let {
  remaining,
  size = 18,
  label,
}: {
  /** Remaining percent, 0–100. */
  remaining: number;
  size?: number;
  /** Text in the middle, spoken as the ring's name. Omit it and the ring is decoration. */
  label?: string;
} = $props();

const clamped = $derived(Math.max(0, Math.min(100, remaining)));
const tone = $derived(meterTone(clamped));
/** A thin logo stroke disappears at band size, so small rings use the mark's inner-arc weight. */
const stroke = $derived(size < 30 ? 6.83 : 4.97);
</script>

<svg
  class="quota-ring quota-ring-{tone}"
  viewBox="0 0 64 64"
  width={size}
  height={size}
  role={label ? "img" : undefined}
  aria-label={label}
  aria-hidden={label ? undefined : "true"}
>
  <circle class="quota-ring-track" cx="32" cy="32" r="22.37" fill="none" stroke-width={stroke} />
  {#if clamped > 0}
    <circle
      class="quota-ring-arc"
      cx="32"
      cy="32"
      r="22.37"
      fill="none"
      stroke-width={stroke}
      stroke-linecap={clamped < 100 ? "round" : "butt"}
      pathLength="100"
      stroke-dasharray="{clamped} 100"
      transform="rotate(-90 32 32)"
    />
  {/if}
  {#if label}
    <text x="32" y="37" text-anchor="middle">{label}</text>
  {/if}
</svg>

<style>
.quota-ring {
  display: block;
  flex: none;
  overflow: visible;
}

.quota-ring-track {
  stroke: var(--meter-track);
}

.quota-ring-good .quota-ring-arc {
  stroke: var(--quota-healthy);
}

.quota-ring-warn .quota-ring-arc {
  stroke: var(--quota-warning);
}

.quota-ring-critical .quota-ring-arc {
  stroke: var(--quota-critical);
}

text {
  fill: var(--ink);
  font-family: var(--rounded);
  font-size: 14px;
  font-variant-numeric: tabular-nums;
  font-weight: 500;
}
</style>
