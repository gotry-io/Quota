<script lang="ts">
import { page } from "$app/state";
import PageHeader from "$lib/components/PageHeader.svelte";
import { DASHBOARD_PATH, isAccountShellPath } from "$lib/routes";

const missing = $derived(page.status === 404);
// The account shell leaves the column to its own layout, which an error replaces.
const ownColumn = $derived(page.data.viewer != null && isAccountShellPath(page.url.pathname));
</script>

<svelte:head>
  <title>Quota</title>
</svelte:head>

<div class:wrap={ownColumn}>
  <PageHeader id="error-title">
    {#snippet eyebrow()}{missing ? "Not found" : "Error"}{/snippet}
    {#if missing}
      <b>This page is unavailable.</b> It may have moved, or the link is incomplete.
    {:else}
      <b>Quota could not load this page.</b> Refresh to try again.
    {/if}
    {#snippet controls()}
      <a class="pill primary" href={DASHBOARD_PATH}>Go to Home</a>
      <a class="pill" href="/">Quota site</a>
    {/snippet}
  </PageHeader>
</div>
