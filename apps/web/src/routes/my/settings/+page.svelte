<script lang="ts">
import { onMount } from "svelte";
import { replaceState } from "$app/navigation";
import { page } from "$app/state";
import type { AccountResponse, AccountSettingsResponseRead } from "@gotry-io/quota-protocol";
import { ACCOUNT_SETTINGS_DEFAULT_THRESHOLDS } from "@gotry-io/quota-protocol";
import { deleteAccount, fetchAccount } from "$lib/account-client";
import {
  type AccountError,
  accountNoticeActionLabel,
  accountNoticeRetry,
  IDENTITY_TAKEN_COPY,
} from "$lib/account-errors";
import { getAccountStore } from "$lib/account-store.svelte.ts";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import MonthlyBudget from "$lib/components/MonthlyBudget.svelte";
import PageHeader from "$lib/components/PageHeader.svelte";
import PublicProfileSettings from "$lib/components/PublicProfileSettings.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import SignInMethodSettings from "$lib/components/SignInMethodSettings.svelte";
import SplitSection from "$lib/components/SplitSection.svelte";
import { DELETE_ACCOUNT_RETURN_PATH, isLinkedTaken, LINKED_TAKEN_PARAM } from "$lib/routes";
import type { WebDocumentViewer } from "$lib/server/document-port";

const store = getAccountStore();
const viewer = $derived((page.data.viewer as WebDocumentViewer | null | undefined) ?? null);
let account = $state<AccountResponse | null>(null);
let accountError = $state<AccountError | null>(null);
let settings = $state<AccountSettingsResponseRead | null>(null);
let deleteHeading = $state<HTMLHeadingElement | null>(null);
let confirmingDelete = $state(false);
let deleting = $state(false);
let linkedTakenNotice = $state(isLinkedTaken(page.url));

const customThresholds = $derived(settings ? Object.keys(settings.alerts.thresholds).length : 0);

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

async function onDeleteAccount(): Promise<void> {
  deleting = true;
  const outcome = await deleteAccount(DELETE_ACCOUNT_RETURN_PATH);
  if (outcome !== "ok") {
    deleting = false;
    store.setError(outcome);
    return;
  }
  window.location.assign("/");
}

function onOff(value: boolean): string {
  return value ? "On" : "Off";
}
</script>

<svelte:head>
  <title>Settings · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

<PageHeader>
  {#snippet eyebrow()}Settings{/snippet}
  Everything here follows your <b>Account</b> on every device.
</PageHeader>

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

<SplitSection
  id="sign-in-methods-title"
  title="Sign-in methods"
  description="One Account, however you sign in. Keep at least one."
>
  {#if account}
    <SignInMethodSettings
      identities={account.identities}
      onChanged={loadAccount}
      onError={(error) => store.setError(error)}
    />
  {:else if !accountError}
    <LoadingBlock lines={3} label="Loading sign-in methods" />
  {/if}
</SplitSection>

<SplitSection
  id="budget-title"
  title="Monthly budget"
  description="API-equivalent cost per calendar month. This budget follows your Account."
>
  <MonthlyBudget {store} onSettings={(next) => (settings = next)} />
</SplitSection>

<SplitSection
  id="notifications-title"
  title="Notifications"
  description="QuotaBar and Quota for iPhone deliver these, and are where you change them."
>
  {#if settings}
    <div class="split-row">
      <span class="split-row-title">Low quota</span>
      <span class="split-row-value">
        {customThresholds === 0
          ? `Below ${ACCOUNT_SETTINGS_DEFAULT_THRESHOLDS.join("% and ")}%`
          : `Below ${ACCOUNT_SETTINGS_DEFAULT_THRESHOLDS.join("% and ")}%, ${customThresholds} set per subscription`}
      </span>
    </div>
    <div class="split-row">
      <span class="split-row-title">Reset reminders</span>
      <span class="split-row-value">{onOff(settings.alerts.reset_reminders)}</span>
    </div>
    <div class="split-row">
      <span class="split-row-title">May run out before reset</span>
      <span class="split-row-value">{onOff(settings.alerts.pace_alerts)}</span>
    </div>
  {:else}
    <LoadingBlock lines={3} label="Loading notifications" />
  {/if}
</SplitSection>

<SplitSection
  id="privacy-title"
  title="Privacy"
  description="What leaves your Macs beyond Usage totals. Change it in QuotaBar or Quota for iPhone."
>
  {#if settings}
    <div class="split-row">
      <div>
        <div class="split-row-title">Quota history follows the Account</div>
        <div class="split-row-detail">Remaining-quota readings over time, shared by your devices.</div>
      </div>
      <span class="split-row-value">{onOff(settings.history?.sync ?? false)}</span>
    </div>
  {:else}
    <LoadingBlock lines={1} label="Loading privacy" />
  {/if}
</SplitSection>

<SplitSection
  id="public-page"
  title="Public page"
  description="A page of your Usage totals. It never shows quota, devices, or plans."
>
  <PublicProfileSettings />
</SplitSection>

<SplitSection
  id="account-title"
  title="Account"
  description="Deleting removes every Device, reading, and Usage total."
>
  <div class="split-row">
    <div>
      <div class="split-row-title">Signed in as</div>
      <div class="split-row-detail">{viewer?.displayLabel ?? "—"}</div>
    </div>
  </div>
  <div id="delete-account-section" class="split-row">
    <div>
      <h3 id="account-actions-title" class="split-row-title" tabindex="-1" bind:this={deleteHeading}>
        Delete Account
      </h3>
      <p class="split-row-detail">
        Removes this Account, every Device, all Quota and Usage data, and its sessions.
      </p>
    </div>
    {#if confirmingDelete}
      <div class="split-row-actions">
        <button class="pill" type="button" onclick={() => (confirmingDelete = false)}>Cancel</button>
        <button
          id="delete-account"
          class="pill danger"
          type="button"
          disabled={deleting}
          onclick={() => void onDeleteAccount()}>Delete Account and data</button
        >
      </div>
    {:else}
      <button class="pill danger" type="button" onclick={() => (confirmingDelete = true)}
        >Delete Account…</button
      >
    {/if}
  </div>
</SplitSection>
