<script lang="ts">
import { onMount } from "svelte";
import { page } from "$app/state";
import { createAccountStore, setAccountStore } from "$lib/account-store.svelte.ts";
import AccountNav from "$lib/components/AccountNav.svelte";

let { children } = $props();

const store = createAccountStore();
setAccountStore(store);

onMount(() => {
  void store.ensureSummary().then(() => {
    void store.ensureActivity(store.activityRange);
  });
});
</script>

<section id="dashboard-view" class="dashboard" aria-labelledby="dashboard-title">
  <div class="dashboard-heading">
    <div>
      <p class="eyebrow">Account</p>
      <h1 id="dashboard-title">Quota</h1>
    </div>
  </div>
  <AccountNav currentPath={page.url.pathname} />
  {@render children()}
</section>
