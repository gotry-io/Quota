<script lang="ts">
import { formatCost } from "$lib/format";
import { type TotalsView, tokenMix } from "$lib/model-usage";

/**
 * One bar of cache read, cache write, fresh input, and output that adds up to the period's
 * tokens, and what cache saved against list price ([`docs/design.md`](../../../../../docs/design.md),
 * Token mix; ADR 0036).
 */
let {
  totals,
  cacheSaved,
}: {
  totals: TotalsView;
  cacheSaved: { amount_microusd: string | null; status: string };
} = $props();

const mix = $derived(tokenMix(totals));

function percent(value: number): string {
  if (value > 0 && value < 0.005) return "<1%";
  return `${Math.round(value * 100)}%`;
}

const parts = $derived(
  mix
    ? [
        { label: "Cache read", value: mix.cacheRead, color: "var(--chart-cache)" },
        { label: "Cache write", value: mix.cacheWrite, color: "var(--chart-cache-write)" },
        { label: "Fresh input", value: mix.freshInput, color: "var(--chart-input)" },
        { label: "Output", value: mix.output, color: "var(--chart-output)" },
      ]
    : [],
);
</script>

{#if mix}
  <div
    class="mix-bar"
    role="img"
    aria-label={`Token mix: ${parts.map((part) => `${part.label.toLowerCase()} ${percent(part.value)}`).join(", ")}`}
  >
    {#each parts as part (part.label)}
      {#if part.value > 0}
        <i style:flex-grow={part.value} style:background={part.color}></i>
      {/if}
    {/each}
  </div>
  <dl class="mix-legend">
    {#each parts as part (part.label)}
      <div style:--part={part.color}>
        <dt>{part.label}</dt>
        <dd>{percent(part.value)}</dd>
        {#if part.label === "Output" && mix.reasoningOfOutput > 0}
          <dd class="note">{percent(mix.reasoningOfOutput)} of it reasoning</dd>
        {/if}
      </div>
    {/each}
    {#if cacheSaved.amount_microusd !== null}
      <div style:--part="var(--brand)">
        <dt>Saved by cache</dt>
        <dd>{formatCost(cacheSaved)}</dd>
        <dd class="note">vs list price</dd>
      </div>
    {/if}
  </dl>
{:else}
  <p class="empty-state">No tokens in this period.</p>
{/if}

<style>
.mix-bar {
  display: flex;
  gap: 2px;
  height: 14px;
  overflow: hidden;
  border-radius: 5px;
}

.mix-bar i {
  flex-basis: 0;
  min-width: 2px;
}

.mix-legend {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 10px 16px;
  margin: 12px 0 0;
}

.mix-legend div {
  display: grid;
  gap: 1px;
  padding-left: 10px;
  border-left: 2px solid var(--part);
}

dt {
  color: var(--body);
  font-size: 12px;
}

dd {
  margin: 0;
  font-family: var(--rounded);
  font-size: 19px;
  font-variant-numeric: tabular-nums;
  font-weight: 500;
}

dd.note {
  color: var(--body);
  font-family: var(--sans);
  font-size: 11px;
  font-weight: 400;
}

@media (max-width: 768px) {
  .mix-legend {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}
</style>
