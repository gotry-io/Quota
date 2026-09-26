<script lang="ts">
import type { Snippet } from "svelte";

/**
 * A two-column group: the heading and one sentence about it on the left, its rows on the right.
 * Settings and Download use it so a short form keeps the page's full width instead of a narrow
 * column of its own.
 */
let {
  id,
  title,
  description,
  children,
}: {
  id: string;
  title: string;
  description?: string;
  children: Snippet;
} = $props();
</script>

<section class="split-section" aria-labelledby={id} id={`${id}-group`}>
  <div class="split-section-heading">
    <h2 {id}>{title}</h2>
    {#if description}
      <p>{description}</p>
    {/if}
  </div>
  <div class="split-section-rows">
    {@render children()}
  </div>
</section>

<style>
.split-section {
  display: grid;
  grid-template-columns: 280px minmax(0, 1fr);
  gap: 12px 48px;
  padding: 22px 0 30px;
  border-top: 1px solid var(--hairline);
}

h2 {
  margin: 0;
  font-family: var(--rounded);
  font-size: 17px;
  font-weight: 500;
  line-height: 1.3;
}

.split-section-heading p {
  margin: 4px 0 0;
  color: var(--body);
  font-size: 13px;
}

.split-section-rows {
  display: grid;
  min-width: 0;
}

@media (max-width: 960px) {
  .split-section {
    grid-template-columns: minmax(0, 1fr);
  }
}
</style>
