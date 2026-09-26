<script lang="ts">
import type { AccountResponse } from "@gotry-io/quota-protocol";
import { fetchAccount, signOut } from "$lib/account-client";
import {
  type AccountError,
  accountNoticeActionLabel,
  accountNoticeRetry,
  DELETE_ACCOUNT_SIGN_IN_COPY,
} from "$lib/account-errors";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import PageHeader from "$lib/components/PageHeader.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import SignInMethods from "$lib/components/SignInMethods.svelte";
import SignInMethodSettings from "$lib/components/SignInMethodSettings.svelte";
import { isDeleteAccountReturn, SIGN_IN_PATH } from "$lib/routes";
import type { WebDocumentViewer } from "$lib/server/document-port";
import type { PageData } from "./$types";

let { data }: { data: PageData & { viewer: WebDocumentViewer | null } } = $props();

const viewer = $derived(data.viewer);
const deletingAccount = $derived(isDeleteAccountReturn(data.returnTo));
const linking = $derived(data.linking);
let error = $state<string | null>(null);
let account = $state<AccountResponse | null>(null);
let accountError = $state<AccountError | null>(null);

async function loadAccount(): Promise<void> {
  const result = await fetchAccount();
  if (result.status === "ok") {
    account = result.account;
    accountError = null;
    return;
  }
  accountError = result;
}

$effect(() => {
  if (!linking || !viewer || deletingAccount) return;
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

/** Signing out here lands back here, as nobody, with the same return target. */
async function onUseAnotherAccount(event: SubmitEvent): Promise<void> {
  event.preventDefault();
  try {
    await signOut(`${SIGN_IN_PATH}?return_to=${encodeURIComponent(data.returnTo)}`);
  } catch {
    error = "Quota could not sign out this browser session. Refresh and try again.";
  }
}
</script>

<svelte:head>
  <title>{linking ? "Link a sign-in method" : "Sign in"} · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

<PageHeader>
  {#snippet eyebrow()}{linking ? "Link" : "Sign in"}{/snippet}
  {#if deletingAccount}
    <b>{DELETE_ACCOUNT_SIGN_IN_COPY}</b>
  {:else if linking}
    <b>Link a sign-in method</b>
  {:else if viewer}
    This browser is signed in as <b>{viewer.displayLabel}</b>.
  {:else}
    <b>Sign in to Quota.</b> Your Account is the same however you sign in.
  {/if}
  {#snippet meta()}
    {#if deletingAccount}
      <span>Quota needs a recent sign-in before it can delete this Account and its data.</span>
    {:else if linking}
      <span
        >Linking adds a way to sign in to the account you're already using; it never merges two
        accounts.</span
      >
    {/if}
  {/snippet}
</PageHeader>

<div class="sign-in">
  <div class="sign-in-methods">
    {#if deletingAccount}
      <SignInMethods returnTo={data.returnTo} />
    {:else if linking}
      {#if viewer}
        <h2 id="sign-in-methods-title">Sign-in methods</h2>
        {#if accountError}
          <RetryNotice
            message={accountError.message}
            actionLabel={accountNoticeActionLabel(accountError)}
            onRetry={accountNoticeRetry(accountError, () => void loadAccount())}
          />
        {:else if account}
          <div class="split-rows">
            <SignInMethodSettings
              identities={account.identities}
              onChanged={loadAccount}
              onError={(next) => (accountError = next)}
            />
          </div>
        {:else}
          <LoadingBlock lines={3} label="Loading sign-in methods" />
        {/if}
      {:else}
        <SignInMethods returnTo={data.returnTo} />
      {/if}
    {:else if viewer}
      <a class="pill primary" href={data.returnTo} data-sveltekit-reload>
        Continue as {viewer.displayLabel}
      </a>
      <form action="/api/auth/logout" method="post" onsubmit={onUseAnotherAccount}>
        <button class="pill" type="submit">Use a different account</button>
      </form>
    {:else}
      <SignInMethods returnTo={data.returnTo} />
    {/if}
    {#if error}
      <p class="notice" role="alert">{error}</p>
    {/if}
    <p class="sign-in-legal">
      By continuing you agree to the <a href="/terms">Terms</a> and <a href="/privacy">Privacy</a>.
    </p>
  </div>
  <ul class="sign-in-points">
    <li>
      <b>Nothing to set up here</b>
      <span>Sign in with the same method in QuotaBar and your data appears.</span>
    </li>
    <li>
      <b>No provider passwords</b>
      <span>This page never asks for Claude, OpenAI, or other provider credentials.</span>
    </li>
    <li>
      <b>Link more methods later</b>
      <span>Linking adds a way in; it never merges two Accounts.</span>
    </li>
  </ul>
</div>

<style>
.sign-in {
  display: grid;
  grid-template-columns: minmax(0, 420px) minmax(0, 1fr);
  gap: 32px 96px;
  align-items: start;
  padding: 12px 0 40px;
}

.sign-in-methods {
  display: grid;
  gap: 8px;
}

.sign-in-methods :global(.pill) {
  width: 100%;
  min-height: 44px;
  font-size: 14px;
}

.sign-in-methods form {
  margin: 0;
}

.sign-in-methods h2 {
  margin: 0 0 4px;
  font-family: var(--rounded);
  font-size: 17px;
  font-weight: 500;
}

.sign-in-methods .split-rows :global(.pill) {
  width: auto;
  min-height: 32px;
  font-size: 13px;
}

.sign-in-legal {
  margin: 8px 0 0;
  color: var(--body);
  font-size: 12.5px;
}

.sign-in-points {
  display: grid;
  margin: 0;
  padding: 0;
  list-style: none;
}

.sign-in-points li {
  display: grid;
  gap: 2px;
  padding: 12px 0;
  border-bottom: 1px solid var(--hairline);
}

.sign-in-points li:first-child {
  border-top: 1px solid var(--hairline);
}

.sign-in-points b {
  font-weight: 600;
}

.sign-in-points span {
  color: var(--body);
  font-size: 13px;
}

@media (max-width: 960px) {
  .sign-in {
    grid-template-columns: minmax(0, 1fr);
  }
}
</style>
