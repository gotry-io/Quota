<script lang="ts">
import type { Snippet } from "svelte";

/**
 * One section of a page: a hairline on top, a heading row with an optional note on the right,
 * then the body. Sections carry no card border; the hairline is the whole separation.
 */
let {
  id,
  title,
  titleHidden = false,
  note,
  children,
}: {
  /** The heading's id; the section is labelled by it. */
  id: string;
  title: string;
  /** Keeps the heading for assistive technology when the page header already names the body. */
  titleHidden?: boolean;
  note?: Snippet;
  children: Snippet;
} = $props();
</script>

<section class="page-section" aria-labelledby={id}>
  <div class="page-section-heading" class:visually-hidden={titleHidden && !note}>
    <h2 {id} class:visually-hidden={titleHidden}>{title}</h2>
    {#if note}
      <div class="page-section-note">{@render note()}</div>
    {/if}
  </div>
  {@render children()}
</section>

<style>
.page-section {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  gap: 16px;
  min-width: 0;
  padding: 22px 0 36px;
  border-top: 1px solid var(--hairline);
}

.page-section-heading {
  display: flex;
  flex-wrap: wrap;
  gap: 8px 16px;
  align-items: baseline;
  justify-content: space-between;
}

h2 {
  margin: 0;
  font-family: var(--rounded);
  font-size: 19px;
  font-weight: 500;
  line-height: 1.3;
}

.page-section-note {
  color: var(--body);
  font-size: 13px;
}
</style>
