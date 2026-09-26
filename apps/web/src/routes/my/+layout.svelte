<script lang="ts">
import { page } from "$app/state";
import { createAccountStore, setAccountStore } from "$lib/account-store.svelte.ts";
import QuotaBand from "$lib/components/QuotaBand.svelte";

let { children } = $props();

const store = createAccountStore();
setAccountStore(store);

$effect(() => {
  void page.url.pathname;
  void store.ensureSummary();
});

$effect(() => {
  return store.startClock();
});
</script>

{#if store.summary && store.summary.subscriptions.length > 0}
  <QuotaBand
    subscriptions={store.summary.subscriptions}
    selectors={store.subscriptionSelectors}
    now={store.now}
  />
{/if}
<div class="wrap">
  {@render children()}
</div>
