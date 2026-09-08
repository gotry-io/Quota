<script lang="ts">
import { type AccountRead, fetchAccount, signOut } from "$lib/account-client";
import {
  type AccountError,
  accountNoticeActionLabel,
  accountNoticeRetry,
  DELETE_ACCOUNT_SIGN_IN_COPY,
} from "$lib/account-errors";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
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
let account = $state<AccountRead | null>(null);
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

<section class="sign-in-page" aria-labelledby="page-title">
  {#if deletingAccount}
    <h1 id="page-title">{DELETE_ACCOUNT_SIGN_IN_COPY}</h1>
    <p class="hero-summary">
      Quota needs a recent sign-in before it can delete this Account and its data.
    </p>
    <SignInMethods returnTo={data.returnTo} />
  {:else if linking}
    <h1 id="page-title">Link a sign-in method</h1>
    <p class="hero-summary">
      Linking adds a way to sign in to the account you're already using; it never merges two
      accounts.
    </p>
    {#if viewer}
      {#if accountError}
        <RetryNotice
          message={accountError.message}
          actionLabel={accountNoticeActionLabel(accountError)}
          onRetry={accountNoticeRetry(accountError, () => void loadAccount())}
        />
      {:else if account}
        <SignInMethodSettings
          identities={account.identities}
          onChanged={loadAccount}
          onError={(next) => (accountError = next)}
        />
      {:else}
        <LoadingBlock lines={3} label="Loading sign-in methods" />
      {/if}
    {:else}
      <SignInMethods returnTo={data.returnTo} />
    {/if}
  {:else if viewer}
    <h1 id="page-title">You're signed in</h1>
    <p class="hero-summary">Continue as this Account, or sign in as a different one.</p>
    <div class="sign-in-actions">
      <a class="button button-primary" href={data.returnTo} data-sveltekit-reload>
        Continue as {viewer.displayLabel}
      </a>
      <form action="/api/auth/logout" method="post" onsubmit={onUseAnotherAccount}>
        <button class="button button-secondary" type="submit">Use a different account</button>
      </form>
    </div>
  {:else}
    <h1 id="page-title">Sign in to Quota</h1>
    <p class="hero-summary">
      Quota keeps one Account. Every way you sign in reaches the same devices, quota, and Usage.
    </p>
    <SignInMethods returnTo={data.returnTo} />
  {/if}
  {#if error}
    <p class="notice" role="alert">{error}</p>
  {/if}
</section>

<style>
.sign-in-page {
  margin: 0 auto;
  max-width: 26rem;
  padding: 4rem 1.25rem 6rem;
}

.sign-in-page h1 {
  font-size: clamp(1.75rem, 4vw, 2.25rem);
  line-height: 1.15;
}

.sign-in-actions {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  margin-top: 1.5rem;
}

.sign-in-actions :global(.button),
.sign-in-actions form {
  width: 100%;
}

.sign-in-actions :global(.button) {
  justify-content: center;
}
</style>
