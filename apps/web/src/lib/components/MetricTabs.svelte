<script lang="ts" generics="Metric extends string">
import type { Snippet } from "svelte";

/**
 * The chart head: one tab per metric, each carrying its period total, and whatever control the
 * chart adds on the right (Amount / Share). Arrow keys move between tabs.
 */
let {
  tabs,
  selected,
  onSelect,
  panelId,
  label,
  trailing,
}: {
  tabs: ReadonlyArray<{ metric: Metric; label: string; value?: string }>;
  selected: Metric;
  onSelect: (metric: Metric) => void;
  /** The element the tabs control. */
  panelId: string;
  label: string;
  trailing?: Snippet;
} = $props();

const uid = $props.id();

function onKey(event: KeyboardEvent, index: number): void {
  const delta = event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
  if (delta === 0) return;
  event.preventDefault();
  const next = tabs[(index + delta + tabs.length) % tabs.length];
  if (!next) return;
  onSelect(next.metric);
  document.getElementById(`${uid}-${next.metric}`)?.focus();
}
</script>

<div class="metric-head">
  <div class="metric-tabs" role="tablist" aria-label={label}>
    {#each tabs as tab, index (tab.metric)}
      <button
        type="button"
        role="tab"
        id="{uid}-{tab.metric}"
        aria-selected={selected === tab.metric}
        aria-controls={panelId}
        tabindex={selected === tab.metric ? 0 : -1}
        onclick={() => onSelect(tab.metric)}
        onkeydown={(event) => onKey(event, index)}
      >
        <span>{tab.label}</span>
        {#if tab.value !== undefined}
          <b>{tab.value}</b>
        {/if}
      </button>
    {/each}
  </div>
  {#if trailing}
    <div class="metric-trailing">{@render trailing()}</div>
  {/if}
</div>

<style>
.metric-head {
  display: flex;
  flex-wrap: wrap;
  gap: 8px 22px;
  align-items: end;
  justify-content: space-between;
  border-bottom: 1px solid var(--hairline);
}

.metric-tabs {
  display: flex;
  gap: 22px;
  min-width: 0;
  overflow-x: auto;
  scrollbar-width: none;
}

button {
  display: grid;
  gap: 2px;
  margin-bottom: -1px;
  padding: 0 0 10px;
  border: 0;
  border-bottom: 2px solid transparent;
  background: none;
  color: var(--body);
  font-size: 12.5px;
  font-weight: 500;
  text-align: left;
  white-space: nowrap;
  cursor: pointer;
}

button b {
  color: var(--ink);
  font-family: var(--rounded);
  font-size: 22px;
  font-variant-numeric: tabular-nums;
  font-weight: 500;
}

button[aria-selected="true"] {
  border-bottom-color: var(--ink);
  color: var(--ink);
}

.metric-trailing {
  display: flex;
  gap: 8px;
  align-items: center;
  padding-bottom: 10px;
  color: var(--body);
  font-size: 12.5px;
}
</style>
