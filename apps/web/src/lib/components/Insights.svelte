<script lang="ts">
import type { Insight } from "$lib/usage-insights";

/** Up to four sentences from the reader's numbers, figures in ink and model names in mono. */
let { insights }: { insights: readonly Insight[] } = $props();
</script>

<ul class="insights">
  {#each insights as insight (insight.id)}
    <li class="tone-{insight.tone}">
      <span
        >{#each insight.parts as part, index (index)}{#if part.kind === "figure"}<b>{part.text}</b
            >{:else if part.kind === "model"}<span class="model">{part.text}</span
            >{:else if part.kind === "link"}<a href={part.href}>{part.text}</a
            >{:else}{part.text}{/if}{/each}</span
      >
    </li>
  {/each}
</ul>

<style>
.insights {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0 48px;
  margin: 0;
  padding: 0;
  list-style: none;
}

li {
  display: grid;
  grid-template-columns: 16px 1fr;
  gap: 8px;
  padding: 12px 0;
  border-bottom: 1px solid var(--hairline);
  color: var(--body);
  font-size: 15.5px;
}

li::before {
  width: 7px;
  height: 7px;
  margin-top: 9px;
  border-radius: 9999px;
  background: var(--ink);
  content: "";
}

li.tone-good::before {
  background: var(--brand);
}

li.tone-warn::before {
  background: var(--quota-warning);
}

b {
  color: var(--ink);
  font-weight: 600;
}

.model {
  color: var(--ink);
  font-family: var(--mono);
  font-size: 0.92em;
  white-space: nowrap;
}

a {
  color: var(--ink);
}

@media (max-width: 960px) {
  .insights {
    grid-template-columns: minmax(0, 1fr);
  }
}
</style>
