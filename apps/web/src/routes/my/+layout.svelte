<script lang="ts">
import { onMount } from "svelte";
import { page } from "$app/state";
import { accountStatusLine } from "$lib/account-overview";
import { createAccountStore, setAccountStore } from "$lib/account-store.svelte.ts";
import { accountPageTitle, isSubscriptionPath } from "$lib/routes";

let { children } = $props();

const store = createAccountStore();
setAccountStore(store);

const title = $derived(accountPageTitle(page.url.pathname));
const showHeading = $derived(!isSubscriptionPath(page.url.pathname));
const status = $derived(store.summary ? accountStatusLine(store.summary) : null);

onMount(() => {
  void store.ensureSummary().then(() => {
    void store.ensureActivity(store.activityRange);
  });
});
</script>

<section
  id="dashboard-view"
  class="dashboard"
  aria-labelledby={showHeading ? "dashboard-title" : undefined}
>
  {#if showHeading}
    <header class="dashboard-page-heading">
      <h1 id="dashboard-title">{title}</h1>
      {#if status}
        <p class="dashboard-status">{status}</p>
      {/if}
    </header>
  {/if}
  {@render children()}
</section>
