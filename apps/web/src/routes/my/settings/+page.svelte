<script lang="ts">
import { onMount } from "svelte";
import { replaceState } from "$app/navigation";
import { page } from "$app/state";
import type { AccountResponse } from "@gotry-io/quota-protocol";
import { deleteAccount, fetchAccount } from "$lib/account-client";
import {
  type AccountError,
  accountNoticeActionLabel,
  accountNoticeRetry,
  IDENTITY_TAKEN_COPY,
} from "$lib/account-errors";
import { viewerInitial } from "$lib/account-overview";
import { getAccountStore } from "$lib/account-store.svelte.ts";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import PublicProfileSettings from "$lib/components/PublicProfileSettings.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import SignInMethodSettings from "$lib/components/SignInMethodSettings.svelte";
import ThemeToggle from "$lib/components/ThemeToggle.svelte";
import { DELETE_ACCOUNT_RETURN_PATH, isLinkedTaken, LINKED_TAKEN_PARAM } from "$lib/routes";
import type { WebDocumentViewer } from "$lib/server/document-port";

const store = getAccountStore();
const viewer = $derived((page.data.viewer as WebDocumentViewer | null | undefined) ?? null);
const initial = $derived(viewerInitial(viewer?.displayLabel));
let account = $state<AccountResponse | null>(null);
let accountError = $state<AccountError | null>(null);
let deleteHeading = $state<HTMLHeadingElement | null>(null);
let linkedTakenNotice = $state(isLinkedTaken(page.url));

async function loadAccount(): Promise<void> {
  const result = await fetchAccount();
  if (result.status === "ok") {
    account = result.account;
    accountError = null;
    return;
  }
  accountError = result;
}

onMount(() => {
  if (!linkedTakenNotice || !isLinkedTaken(page.url)) return;
  const stripped = new URL(page.url);
  stripped.searchParams.delete(LINKED_TAKEN_PARAM);
  const path = `${stripped.pathname}${stripped.search}${stripped.hash}`;
  const id = window.setTimeout(() => {
    replaceState(path, page.state);
  }, 0);
  return () => window.clearTimeout(id);
});

$effect(() => {
  let cancelled = false;
  void fetchAccount().then((result) => {
    if (cancelled) return;
    if (result.status === "ok") {
      account = result.account;
      accountError = null;
      return;
    }
    accountError = result;
  });
  return () => {
    cancelled = true;
  };
});

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
  const outcome = await deleteAccount(DELETE_ACCOUNT_RETURN_PATH);
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

{#if linkedTakenNotice}
  <p class="notice" role="alert">{IDENTITY_TAKEN_COPY}</p>
{/if}

{#if store.loadError}
  <RetryNotice
    id="account-error"
    message={store.loadError.message}
    actionLabel={accountNoticeActionLabel(store.loadError)}
    onRetry={accountNoticeRetry(store.loadError, () => void store.refresh())}
  />
{/if}

{#if accountError}
  <RetryNotice
    id="identities-error"
    message={accountError.message}
    actionLabel={accountNoticeActionLabel(accountError)}
    onRetry={accountNoticeRetry(accountError, () => void loadAccount())}
  />
{/if}

<section class="settings-group" aria-labelledby="appearance-title">
  <h2 id="appearance-title">Appearance</h2>
  <div class="settings-row">
    <p>Theme</p>
    <ThemeToggle id="settings-theme-toggle" menuPlacement="down" />
  </div>
</section>

{#if account}
  <SignInMethodSettings
    identities={account.identities}
    onChanged={loadAccount}
    onError={(error) => store.setError(error)}
  />
{:else if !accountError}
  <section class="settings-group" aria-labelledby="sign-in-methods-title">
    <h2 id="sign-in-methods-title">Sign-in methods</h2>
    <LoadingBlock lines={3} label="Loading sign-in methods" />
  </section>
{/if}

<section class="settings-group" aria-labelledby="account-title">
  <h2 id="account-title">Account</h2>
  <div class="settings-row">
    <p>Signed in as</p>
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

<PublicProfileSettings />

<section class="settings-group" aria-labelledby="legal-title">
  <h2 id="legal-title">Legal</h2>
  <ul class="settings-links">
    <li><a href="/privacy">Privacy</a></li>
    <li><a href="/terms">Terms</a></li>
    <li><a href="/support">Support</a></li>
  </ul>
</section>
