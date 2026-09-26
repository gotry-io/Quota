<script lang="ts">
import type { Snippet } from "svelte";

/**
 * The header every page opens with: an eyebrow, one sentence as the page's `h1`, controls to the
 * right, and a meta line under it.
 *
 * The sentence is body colour and the parts wrapped in `<b>` are ink, so the reader's own numbers
 * are what stands out rather than the words around them.
 */
let {
  id = "page-title",
  eyebrow,
  children,
  controls,
  meta,
}: {
  id?: string;
  eyebrow?: Snippet;
  children: Snippet;
  controls?: Snippet;
  meta?: Snippet;
} = $props();
</script>

<header class="page-header">
  {#if eyebrow}
    <div class="eyebrow page-header-eyebrow">{@render eyebrow()}</div>
  {/if}
  <h1 {id}>{@render children()}</h1>
  {#if controls}
    <div class="page-header-controls">{@render controls()}</div>
  {/if}
  {#if meta}
    <div class="page-header-meta">{@render meta()}</div>
  {/if}
</header>

<style>
.page-header {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: 14px 32px;
  align-items: end;
  padding: 40px 0 24px;
}

.page-header-eyebrow {
  grid-column: 1 / -1;
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  align-items: center;
}

.page-header-eyebrow :global(a) {
  text-decoration: none;
}

.page-header-eyebrow :global(a:hover) {
  color: var(--ink);
}

h1 {
  max-width: 24em;
  margin: 0;
  color: var(--body);
  font-family: var(--rounded);
  font-size: 32px;
  font-weight: 500;
  line-height: 1.22;
  text-wrap: balance;
}

h1 :global(b) {
  color: var(--ink);
  font-weight: 500;
}

.page-header-controls {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  align-items: center;
  justify-content: flex-end;
}

.page-header-meta {
  grid-column: 1 / -1;
  display: flex;
  flex-wrap: wrap;
  gap: 6px 22px;
  align-items: center;
  color: var(--body);
  font-size: 14px;
}

.page-header-meta :global(b) {
  color: var(--ink);
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}

@media (max-width: 768px) {
  .page-header {
    grid-template-columns: minmax(0, 1fr);
    padding-top: 24px;
  }

  h1 {
    font-size: 24px;
  }

  .page-header-controls {
    justify-content: flex-start;
  }
}
</style>
