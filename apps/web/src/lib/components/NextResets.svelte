<script lang="ts">
import { resetCopy } from "$lib/format";
import { RESET_HORIZON_MS, type ResetLane } from "$lib/quota-overview";

/**
 * The next seven days in local time, one lane per current subscription, a ring per refill in the
 * band colour of the window it refills ([`docs/design.md`](../../../../../docs/design.md), Next
 * resets). Its text alternative is each window's **Resets** line.
 */
let { lanes, now }: { lanes: readonly ResetLane[]; now: Date } = $props();

let width = $state(560);
const W = $derived(Math.max(420, width));
const L = 104;
const R = 10;
const T = 18;
const LANE = 24;
const H = $derived(T + lanes.length * LANE + 4);

function x(at: number): number {
  const span = Math.min(Math.max(at - now.getTime(), 0), RESET_HORIZON_MS);
  return L + (span / RESET_HORIZON_MS) * (W - L - R);
}

const midnights = $derived.by(() => {
  const marks: Array<{ at: number; label: string }> = [];
  const start = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
  for (let day = 0; day < 7; day += 1) {
    const at = new Date(start.getFullYear(), start.getMonth(), start.getDate() + day);
    marks.push({
      at: at.getTime(),
      label: at.toLocaleDateString("en-US", { weekday: "short" }),
    });
  }
  return marks;
});

const toneColor: Record<string, string> = {
  good: "var(--quota-healthy)",
  warn: "var(--quota-warning)",
  critical: "var(--quota-critical)",
};
</script>

<!-- A region that scrolls sideways when narrow must be reachable by keyboard. -->
<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
<div class="resets" bind:clientWidth={width} role="region" aria-label="Next resets" tabindex="0">
  <svg viewBox="0 0 {W} {H}" width={W} height={H} aria-hidden="true">
    <text x={L} y="10">Now</text>
    {#each midnights as mark (mark.at)}
      <line class="day" x1={x(mark.at)} x2={x(mark.at)} y1={T - 4} y2={H} />
      {#if x(mark.at) - L > 30}
        <text x={x(mark.at) + 3} y="10">{mark.label}</text>
      {/if}
    {/each}
    {#each lanes as lane, index (lane.key)}
      {@const cy = T + index * LANE + LANE / 2}
      <text class="lane" x="0" y={cy + 4}>{lane.name}</text>
      <line class="rail" x1={L} x2={W - R} y1={cy} y2={cy} />
      {#each lane.resets as reset (reset.at)}
        {@const cx = x(reset.at)}
        {@const right = cx > W - 150}
        <circle {cx} {cy} r="4.5" stroke={toneColor[reset.tone]} />
        <text x={right ? cx - 9 : cx + 9} y={cy + 4} text-anchor={right ? "end" : "start"}
          >{reset.titles.join(" · ")}</text
        >
      {/each}
    {/each}
  </svg>
  <ul class="visually-hidden">
    {#each lanes as lane (lane.key)}
      {#each lane.resets as reset (reset.at)}
        <li>{lane.name} {reset.titles.join(" and ")}: {resetCopy(reset.at, now)}</li>
      {/each}
    {/each}
  </ul>
</div>

<style>
.resets {
  min-width: 0;
  overflow-x: auto;
}

svg {
  display: block;
  width: 100%;
  min-width: 420px;
  height: auto;
  overflow: visible;
}

text {
  fill: var(--body);
  font: 11px var(--sans);
}

text.lane {
  fill: var(--ink);
  font-weight: 500;
}

.day {
  stroke: var(--hairline);
}

.rail {
  stroke: var(--hairline);
  stroke-dasharray: 1 3;
}

circle {
  fill: var(--canvas);
  stroke-width: 2;
}
</style>
