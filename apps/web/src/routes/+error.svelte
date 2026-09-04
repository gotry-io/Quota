<script lang="ts">
import { page } from "$app/state";
</script>

<svelte:head>
  <title>Quota</title>
</svelte:head>

<section class="dashboard" aria-labelledby="error-title">
  <div class="dashboard-heading">
    <div>
      <p class="eyebrow">Quota</p>
      <h1 id="error-title">
        {#if page.status === 404}
          This page is unavailable.
        {:else}
          Quota could not load this page.
        {/if}
      </h1>
    </div>
  </div>
  <p class="hero-summary">
    {#if page.status === 404}
      This page does not exist.
    {:else}
      Refresh to try again.
    {/if}
  </p>
</section>
