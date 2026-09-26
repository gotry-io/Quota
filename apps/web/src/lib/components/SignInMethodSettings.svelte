<script lang="ts">
import {
  type AccountIdentity,
  type IdentityProvider,
  identityProviderDisplayName,
} from "@gotry-io/quota-protocol";
import { requestEmailSignInLink, unlinkIdentity } from "$lib/account-client";
import { type AccountError, KEEP_ONE_SIGN_IN_COPY } from "$lib/account-errors";
import { identityLinkHref, SETTINGS_PATH, SIGN_IN_METHOD_ORDER } from "$lib/routes";

let {
  identities,
  onChanged,
  onError,
}: {
  identities: AccountIdentity[];
  onChanged: () => Promise<void>;
  onError: (error: AccountError) => void;
} = $props();

let email = $state("");
let emailOpen = $state(false);
let sent = $state(false);
let sending = $state(false);
let unlinking = $state<IdentityProvider | null>(null);
/** The channel asking whether to unlink; the question sits in its own row, not a dialog. */
let confirming = $state<IdentityProvider | null>(null);
let emailError = $state<string | null>(null);

const bound = $derived(new Map(identities.map((identity) => [identity.provider, identity])));
const last = $derived(identities.length <= 1);

async function onUnlink(provider: IdentityProvider): Promise<void> {
  if (last) return;
  unlinking = provider;
  const outcome = await unlinkIdentity(provider, SETTINGS_PATH);
  unlinking = null;
  confirming = null;
  if (outcome === "ok" || outcome === "last_identity") {
    await onChanged();
    return;
  }
  onError(outcome);
}

async function onSendLink(): Promise<void> {
  sending = true;
  emailError = null;
  try {
    const result = await requestEmailSignInLink({
      email,
      returnTo: SETTINGS_PATH,
      intent: "link",
    });
    if (result === "accepted") {
      sent = true;
      return;
    }
    if (result === "invalid") {
      emailError = "Enter an email address.";
      return;
    }
    if (result === "rate_limited") {
      emailError = "Too many sign-in attempts. Wait a moment and try again.";
      return;
    }
    emailError = "Quota could not send a sign-in link. Refresh and try again.";
  } finally {
    sending = false;
  }
}

function onUseAnotherWay(): void {
  sent = false;
  emailOpen = false;
  emailError = null;
}
</script>

{#each SIGN_IN_METHOD_ORDER as provider (provider)}
  {@const identity = bound.get(provider)}
  <div class="split-row" data-provider={provider}>
    <div>
      <div class="split-row-title">{identityProviderDisplayName(provider)}</div>
      <div class="split-row-detail">{identity ? identity.label : "Not linked"}</div>
    </div>
    {#if identity}
      {#if confirming === provider}
        <div class="split-row-actions">
          <span class="split-row-detail">You can link it again later.</span>
          <button class="pill" type="button" onclick={() => (confirming = null)}>Cancel</button>
          <button
            class="pill danger"
            type="button"
            disabled={unlinking === provider}
            aria-label="Unlink {identityProviderDisplayName(provider)}"
            onclick={() => void onUnlink(provider)}>Unlink</button
          >
        </div>
      {:else}
        <button
          class="pill"
          type="button"
          disabled={last}
          aria-describedby={last ? "keep-one-signin" : undefined}
          onclick={() => (confirming = provider)}>Unlink</button
        >
      {/if}
    {:else if provider === "email"}
      {#if sent}
        <div class="email-sent" role="status">
          <h3>Check your email</h3>
          <p>A sign-in link is on its way. It expires in 15 minutes.</p>
          <button class="pill" type="button" onclick={onUseAnotherWay}>Use another way</button>
        </div>
      {:else if emailOpen}
        <form
          class="email-link"
          method="post"
          action="/api/auth/email/start"
          onsubmit={(event) => {
            event.preventDefault();
            void onSendLink();
          }}
        >
          <label class="visually-hidden" for="link-email">Email</label>
          <input
            id="link-email"
            class="input"
            type="email"
            name="email"
            autocomplete="email"
            inputmode="email"
            maxlength="254"
            placeholder="you@example.com"
            required
            bind:value={email}
          />
          <button class="pill primary" type="submit" disabled={sending}>Send sign-in link</button>
        </form>
      {:else}
        <button class="pill" type="button" onclick={() => (emailOpen = true)}>Link</button>
      {/if}
    {:else}
      <a class="pill" href={identityLinkHref(provider)} data-sveltekit-reload>Link</a>
    {/if}
  </div>
  {#if provider === "email" && emailError}
    <p class="notice" role="alert">{emailError}</p>
  {/if}
{/each}
{#if last}
  <p id="keep-one-signin" class="split-note">{KEEP_ONE_SIGN_IN_COPY}</p>
{/if}

<style>
.email-link {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  min-width: min(100%, 20rem);
}

.email-link .input {
  flex: 1;
  min-width: 12rem;
}

.email-sent {
  display: grid;
  justify-items: start;
  gap: 6px;
  max-width: 22rem;
}

.email-sent h3 {
  margin: 0;
  font-size: 14px;
  font-weight: 600;
}

.email-sent p {
  margin: 0;
  color: var(--body);
  font-size: 13px;
}
</style>
