<script lang="ts">
import { page } from "$app/state";
import { deleteAccount } from "$lib/account-client";
import { getAccountDashboard } from "$lib/account-dashboard.svelte.ts";
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import ThemeToggle from "$lib/components/ThemeToggle.svelte";

const dashboard = getAccountDashboard();
let deleteHeading = $state<HTMLHeadingElement | null>(null);

$effect(() => {
  const heading = deleteHeading;
  if (page.url.searchParams.get("delete") !== "account" || !heading) return;
  heading.scrollIntoView();
  heading.focus();
});

async function onDeleteAccount(event: Event): Promise<void> {
  if (!window.confirm("Delete this Quota Account and all of its Device, quota, and Usage data?")) {
    return;
  }
  const button = event.currentTarget;
  if (button instanceof HTMLButtonElement) button.disabled = true;
  const outcome = await deleteAccount(`${page.url.pathname}${page.url.search}`);
  if (outcome !== "ok") {
    if (button instanceof HTMLButtonElement) button.disabled = false;
    dashboard.setError(outcome);
    return;
  }
  window.location.assign("/");
}
</script>

<svelte:head>
  <title>Settings · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

{#if dashboard.loadError}
  <RetryNotice
    id="account-error"
    message={dashboard.loadError.message}
    actionLabel={accountNoticeActionLabel(dashboard.loadError)}
    onRetry={accountNoticeRetry(dashboard.loadError, () => void dashboard.loadSummary())}
  />
{/if}

<section class="dashboard-section" aria-labelledby="appearance-title">
  <div class="dashboard-section-heading">
    <div>
      <p class="eyebrow">Preferences</p>
      <h2 id="appearance-title">Appearance</h2>
    </div>
  </div>
  <div class="settings-row">
    <p>Appearance</p>
    <ThemeToggle id="settings-theme-toggle" menuPlacement="down" />
  </div>
</section>

<section
  id="delete-account-section"
  class="dashboard-section danger-zone"
  aria-labelledby="account-actions-title"
>
  <div>
    <p class="eyebrow">Danger zone</p>
    <h2 id="account-actions-title" tabindex="-1" bind:this={deleteHeading}>Delete Account</h2>
    <p>Remove this Account, every Device, all Quota and Usage data, sessions, and deletion controls.</p>
  </div>
  <button
    id="delete-account"
    class="button button-danger"
    type="button"
    onclick={(event) => void onDeleteAccount(event)}>Delete Account and data</button
  >
</section>
