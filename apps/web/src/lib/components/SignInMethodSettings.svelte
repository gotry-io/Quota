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
let emailError = $state<string | null>(null);

const bound = $derived(new Map(identities.map((identity) => [identity.provider, identity])));
const last = $derived(identities.length <= 1);

async function onUnlink(provider: IdentityProvider): Promise<void> {
  if (last) return;
  if (
    !window.confirm(
      `Unlink ${identityProviderDisplayName(provider)} from this Account? You can link it again later.`,
    )
  ) {
    return;
  }
  unlinking = provider;
  const outcome = await unlinkIdentity(provider, SETTINGS_PATH);
  unlinking = null;
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

<section class="settings-group" aria-labelledby="sign-in-methods-title">
  <h2 id="sign-in-methods-title">Sign-in methods</h2>
  {#each SIGN_IN_METHOD_ORDER as provider (provider)}
    {@const identity = bound.get(provider)}
    <div class="settings-row" data-provider={provider}>
      <p>{identityProviderDisplayName(provider)}</p>
      {#if identity}
        <div class="settings-identity-meta">
          <span class="settings-identity-label">{identity.label}</span>
          <button
            class="button button-secondary"
            type="button"
            disabled={last || unlinking === provider}
            aria-describedby={last ? "keep-one-signin" : undefined}
            onclick={() => void onUnlink(provider)}>Unlink</button
          >
        </div>
      {:else if provider === "email"}
        {#if sent}
          <div class="email-sent" role="status">
            <h3>Check your email</h3>
            <p>A sign-in link is on its way. It expires in 15 minutes.</p>
            <button class="button button-secondary" type="button" onclick={onUseAnotherWay}>
              Use another way
            </button>
          </div>
        {:else if emailOpen}
          <form
            class="email-sign-in"
            method="post"
            action="/api/auth/email/start"
            onsubmit={(event) => {
              event.preventDefault();
              void onSendLink();
            }}
          >
            <label class="email-label" for="link-email">Email</label>
            <input
              id="link-email"
              class="email-input"
              type="email"
              name="email"
              autocomplete="email"
              inputmode="email"
              maxlength="254"
              required
              bind:value={email}
            />
            <button class="button button-primary" type="submit" disabled={sending}>
              Send sign-in link
            </button>
          </form>
        {:else}
          <button class="button button-secondary" type="button" onclick={() => (emailOpen = true)}>
            Link
          </button>
        {/if}
      {:else}
        <a class="button button-secondary" href={identityLinkHref(provider)} data-sveltekit-reload>
          Link
        </a>
      {/if}
    </div>
    {#if provider === "email" && emailError}
      <p class="notice" role="alert">{emailError}</p>
    {/if}
  {/each}
  {#if last}
    <p id="keep-one-signin" class="settings-note">{KEEP_ONE_SIGN_IN_COPY}</p>
  {/if}
</section>

<style>
.settings-identity-meta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: flex-end;
  gap: 12px;
  min-width: 0;
}

.settings-identity-label {
  color: var(--body);
  font-size: var(--fs-body);
  overflow-wrap: anywhere;
}

.email-sign-in {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  min-width: min(100%, 16rem);
}

.email-label {
  color: var(--charcoal);
  font-size: 13px;
  font-weight: 600;
}

.email-input {
  width: 100%;
  min-height: 42px;
  padding: 8px 12px;
  border: 1px solid var(--hairline);
  border-radius: 8px;
  background: var(--surface-soft);
  color: var(--ink);
  font-family: inherit;
  font-size: 14px;
}

.email-input:focus {
  outline: 2px solid var(--focus-ring);
  outline-offset: 1px;
}

.email-sent {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0.5rem;
  max-width: 22rem;
  text-align: left;
}

.email-sent h3 {
  margin: 0;
  font-size: 1rem;
  line-height: 1.3;
}

.email-sent p {
  margin: 0;
  color: var(--body);
  line-height: 1.5;
}
</style>
