<script lang="ts">
import { page } from "$app/state";
import { deleteAccount } from "$lib/account-client";
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import { viewerInitial } from "$lib/account-overview";
import { getAccountStore } from "$lib/account-store.svelte.ts";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import ThemeToggle from "$lib/components/ThemeToggle.svelte";
import type { WebDocumentViewer } from "$lib/server/document-port";

const store = getAccountStore();
const viewer = $derived((page.data.viewer as WebDocumentViewer | null | undefined) ?? null);
const initial = $derived(viewerInitial(viewer?.displayLabel));
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
    store.setError(outcome);
    return;
  }
  window.location.assign("/");
}
</script>

<svelte:head>
  <title>Settings · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

{#if store.loadError}
  <RetryNotice
    id="account-error"
    message={store.loadError.message}
    actionLabel={accountNoticeActionLabel(store.loadError)}
    onRetry={accountNoticeRetry(store.loadError, () => void store.refresh())}
  />
{/if}

<section class="settings-group" aria-labelledby="appearance-title">
  <h2 id="appearance-title">Appearance</h2>
  <div class="settings-row">
    <p>Theme</p>
    <ThemeToggle id="settings-theme-toggle" menuPlacement="down" />
  </div>
</section>

<section class="settings-group" aria-labelledby="account-title">
  <h2 id="account-title">Account</h2>
  <div class="settings-row">
    <p>GitHub</p>
    <div class="settings-account-id">
      <span class="account-avatar-fallback" aria-hidden="true">{initial}</span>
      <span>{viewer?.displayLabel ?? "—"}</span>
    </div>
  </div>
  <div id="delete-account-section" class="danger-zone settings-danger">
    <div>
      <h3 id="account-actions-title" tabindex="-1" bind:this={deleteHeading}>Delete Account</h3>
      <p>
        Remove this Account, every Device, all Quota and Usage data, sessions, and deletion
        controls.
      </p>
    </div>
    <button
      id="delete-account"
      class="button button-danger"
      type="button"
      onclick={(event) => void onDeleteAccount(event)}>Delete Account and data</button
    >
  </div>
</section>

<section class="settings-group" aria-labelledby="legal-title">
  <h2 id="legal-title">Legal</h2>
  <ul class="settings-links">
    <li><a href="/privacy">Privacy</a></li>
    <li><a href="/terms">Terms</a></li>
    <li><a href="/support">Support</a></li>
  </ul>
</section>
