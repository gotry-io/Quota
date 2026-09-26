<script lang="ts">
/**
 * The header a published page wears.
 *
 * A public page carries no account state at all: no viewer name, no sign-in prompt beside
 * someone else's Usage, and no Account navigation. What is left is who made the page and one
 * way to find out what Quota is.
 */
import QuotaMark from "$lib/components/QuotaMark.svelte";
</script>

<header class="site-header">
  <div class="wrap site-header-row">
    <a class="brand" href="/" aria-label="Quota home">
      <QuotaMark size={24} />
      <span>Quota</span>
    </a>
    <div class="site-header-actions">
      <a class="pill primary" href="/download">Get Quota</a>
    </div>
  </div>
</header>
