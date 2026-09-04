<script lang="ts">
import { page } from "$app/state";
import { createAccountDashboard, setAccountDashboard } from "$lib/account-dashboard.svelte.ts";
import AccountNav from "$lib/components/AccountNav.svelte";

let { children } = $props();

const dashboard = createAccountDashboard();
setAccountDashboard(dashboard);

$effect(() => {
  void dashboard.loadSummary();
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
