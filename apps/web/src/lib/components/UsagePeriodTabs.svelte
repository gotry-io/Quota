<script lang="ts">
import { USAGE_PERIODS, type UsagePeriodQuery } from "$lib/usage-period";

let {
  selectedQuery,
  onSelectQuery,
}: {
  selectedQuery: UsagePeriodQuery;
  onSelectQuery: (query: UsagePeriodQuery) => void;
} = $props();
</script>

<div class="period-tabs" role="group" aria-label="Usage period">
  {#each USAGE_PERIODS as item (item.query)}
    <button
      class="period-tab"
      type="button"
      aria-pressed={selectedQuery === item.query}
      onclick={() => onSelectQuery(item.query)}>{item.label}</button
    >
  {/each}
</div>
