<script lang="ts">
import { meterTone } from "$lib/account-overview";

/**
 * A linear remaining meter, 0…100 with an exact zero, in the band colour, with the even-pace
 * tick where the pace rule answers ([`docs/design.md`](../../../../../docs/design.md), Meter and
 * Even-pace tick). A fill that ends short of the tick is burning faster than an even pace.
 *
 * Pass `label` only where the meter is the one place the figure is spoken; beside a printed
 * percent it is hidden from assistive technology.
 */
let {
  remaining,
  tick = null,
  thick = false,
  label,
}: {
  remaining: number;
  /** Remaining at an even burn rate now, 0–100, or null. */
  tick?: number | null;
  thick?: boolean;
  label?: string | undefined;
} = $props();

const clamped = $derived(Math.max(0, Math.min(100, remaining)));
</script>

<div
  class="meter meter-{meterTone(clamped)}"
  class:thick
  role={label ? "meter" : undefined}
  aria-label={label}
  aria-valuemin={label ? 0 : undefined}
  aria-valuemax={label ? 100 : undefined}
  aria-valuenow={label ? Math.round(clamped) : undefined}
  aria-hidden={label ? undefined : "true"}
>
  <div class="track"><i style:width="{clamped}%"></i></div>
  {#if tick !== null}
    <span class="tick" style:left="{tick}%" title="Even pace: {Math.round(tick)}%"></span>
  {/if}
</div>

<style>
.meter {
  position: relative;
  margin-top: 6px;
}

.track {
  height: 4px;
  overflow: hidden;
  border-radius: 9999px;
  background: var(--meter-track);
}

.thick .track {
  height: 6px;
}

.track i {
  display: block;
  height: 100%;
  border-radius: 9999px;
  background: var(--quota-healthy);
}

.meter-warn .track i {
  background: var(--quota-warning);
}

.meter-critical .track i {
  background: var(--quota-critical);
}

.tick {
  position: absolute;
  top: -3px;
  width: 2px;
  height: 10px;
  margin-left: -1px;
  border-radius: 1px;
  background: var(--ink);
  opacity: 0.45;
}

.thick .tick {
  top: -2px;
}
</style>
