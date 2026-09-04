<script lang="ts">
import { renderMarkdown } from "$lib/markdown";

let { source, draft = false }: { source: string; draft?: boolean } = $props();

const html = $derived(renderMarkdown(source));
</script>

<section class="document-page" aria-labelledby="page-title">
  {#if draft}
    <p class="document-draft"><span class="count-pill">Draft</span></p>
  {/if}
  <div class="prose">{@html html}</div>
</section>
